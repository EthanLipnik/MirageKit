//
//  MirageMetalFXUpscaler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/18/26.
//
//  MetalFX spatial upscaler that operates on
//  IOSurface-backed CVPixelBuffers and feeds the result back through
//  the existing AVSampleBufferDisplayLayer path.
//

#if canImport(MetalFX)
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalFX
import MirageKit
import os
import VideoToolbox

final class MirageMetalFXUpscaler: @unchecked Sendable {

    // MARK: - Configuration

    struct Configuration: Equatable {
        let inputWidth: Int
        let inputHeight: Int
        let outputWidth: Int
        let outputHeight: Int
        let pixelFormat: OSType
    }

    // MARK: - Metal State

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?

    // MARK: - Scaler State

    private var spatialScaler: MTLFXSpatialScaler?
    private var privateOutputTexture: MTLTexture?
    private var outputPool: CVPixelBufferPool?
    private var currentConfig: Configuration?
    private var loggedUnsupportedFormat: OSType = 0

    // MARK: - Async Pipeline State

    struct PendingFrame {
        let buffer: CVPixelBuffer
        let contentRect: CGRect
        let decodeTime: CFAbsoluteTime
        let presentationTime: CMTime
        let streamID: StreamID
    }

    private let upscaleQueue = DispatchQueue(label: "com.mirage.metalfx-upscale", qos: .userInteractive)
    private var pendingFrameLock = os_unfair_lock()
    private var pendingFrame: PendingFrame?
    private var isProcessing = false

    // MARK: - Fallback YUV→BGRA Conversion

    private var transferSession: VTPixelTransferSession?
    private var conversionPool: CVPixelBufferPool?
    private var conversionPoolDimensions: (width: Int, height: Int) = (0, 0)
    private var loggedFallbackConversion = false

    // MARK: - Init

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            MirageLogger.error(.renderer, "MetalFX upscaler: no Metal device available")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            MirageLogger.error(.renderer, "MetalFX upscaler: failed to create command queue")
            return nil
        }
        self.device = device
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            MirageLogger.error(.renderer, "MetalFX upscaler: failed to create texture cache")
            return nil
        }
        self.textureCache = cache
    }

    // MARK: - Target Output Size

    /// The display-resolution output size. When non-zero, used directly.
    /// When zero, computed from the input frame size and the upscale factor.
    var targetOutputWidth: Int = 0
    var targetOutputHeight: Int = 0

    /// The upscale factor (0.5–0.75) that was applied to reduce the encode
    /// resolution. Used to compute the output size when target is not set.
    var upscaleFactor: Double = 0.5

    // MARK: - Public API

    func configure(_ config: Configuration) -> Bool {
        guard config != currentConfig else { return true }

        guard config.inputWidth > 0, config.inputHeight > 0,
              config.outputWidth > 0, config.outputHeight > 0,
              config.outputWidth > config.inputWidth || config.outputHeight > config.inputHeight else {
            MirageLogger.error(.renderer, "MetalFX upscaler: invalid or non-upscaling dimensions \(config)")
            return false
        }

        let metalFormat = Self.metalPixelFormat(for: config.pixelFormat)
        guard metalFormat != .invalid else {
            if loggedUnsupportedFormat != config.pixelFormat {
                loggedUnsupportedFormat = config.pixelFormat
                MirageLogger.error(
                    .renderer,
                    "MetalFX upscaler: unsupported pixel format \(config.pixelFormat) " +
                    "(MetalFX requires BGRA; ensure the host is updated to switch pixel format when upscaling is enabled)"
                )
            }
            return false
        }

        // Create spatial scaler
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = config.inputWidth
        descriptor.inputHeight = config.inputHeight
        descriptor.outputWidth = config.outputWidth
        descriptor.outputHeight = config.outputHeight
        descriptor.colorTextureFormat = metalFormat
        descriptor.outputTextureFormat = metalFormat
        descriptor.colorProcessingMode = .perceptual

        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            MirageLogger.error(.renderer, "MetalFX upscaler: failed to create spatial scaler")
            return false
        }

        // Create output buffer pool
        guard let pool = createOutputPool(config: config) else {
            MirageLogger.error(.renderer, "MetalFX upscaler: failed to create output pool")
            return false
        }

        // Create a private-storage texture for MetalFX output. IOSurface-backed
        // textures from CVMetalTextureCache use .shared storage, but MetalFX
        // requires .private. We blit from this texture to the shared one after upscaling.
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: metalFormat,
            width: config.outputWidth,
            height: config.outputHeight,
            mipmapped: false
        )
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.shaderWrite, .shaderRead, .renderTarget]

        guard let privateTexture = device.makeTexture(descriptor: textureDescriptor) else {
            MirageLogger.error(.renderer, "MetalFX upscaler: failed to create private output texture")
            return false
        }

        spatialScaler = scaler
        privateOutputTexture = privateTexture
        outputPool = pool
        currentConfig = config

        MirageLogger.renderer(
            "MetalFX upscaler configured: \(config.inputWidth)x\(config.inputHeight) → " +
            "\(config.outputWidth)x\(config.outputHeight)"
        )
        return true
    }

    /// Upscale a decoded frame. Auto-configures the scaler on first call or
    /// when input dimensions change. Returns nil if upscaling is not needed
    /// (input already matches output) or if configuration fails.
    func upscale(_ inputBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let inputWidth = CVPixelBufferGetWidth(inputBuffer)
        let inputHeight = CVPixelBufferGetHeight(inputBuffer)
        let rawPixelFormat = CVPixelBufferGetPixelFormatType(inputBuffer)

        // If the input is not a MetalFX-compatible format, convert YUV→BGRA
        let metalFXBuffer: CVPixelBuffer
        let pixelFormat: OSType
        if Self.metalPixelFormat(for: rawPixelFormat) == .invalid {
            guard let converted = convertToBGRA(inputBuffer, width: inputWidth, height: inputHeight) else {
                return nil
            }
            metalFXBuffer = converted
            pixelFormat = kCVPixelFormatType_32BGRA
        } else {
            metalFXBuffer = inputBuffer
            pixelFormat = rawPixelFormat
        }

        // Compute output size: use explicit target or derive from scale factor
        let outputW: Int
        let outputH: Int
        if targetOutputWidth > 0, targetOutputHeight > 0 {
            outputW = targetOutputWidth
            outputH = targetOutputHeight
        } else if upscaleFactor > 0, upscaleFactor < 1.0 {
            // input = display * factor → display = input / factor
            outputW = Int((Double(inputWidth) / upscaleFactor).rounded())
            outputH = Int((Double(inputHeight) / upscaleFactor).rounded())
        } else {
            return nil
        }

        // Skip upscaling if input already matches output
        guard outputW > inputWidth || outputH > inputHeight else { return nil }

        let needed = Configuration(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputW,
            outputHeight: outputH,
            pixelFormat: pixelFormat
        )
        if needed != currentConfig {
            guard configure(needed) else { return nil }
        }

        guard let scaler = spatialScaler,
              let privateOutput = privateOutputTexture,
              let pool = outputPool,
              let textureCache else {
            return nil
        }

        // Wrap input as MTLTexture (zero-copy via IOSurface)
        guard let inputTexture = makeTexture(
            from: metalFXBuffer,
            cache: textureCache
        ) else {
            return nil
        }

        // Dequeue output buffer from pool
        var outputBuffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard poolStatus == kCVReturnSuccess, let outputBuffer else {
            MirageLogger.error(.renderer, "MetalFX upscaler: output pool exhausted")
            return nil
        }

        // Wrap output as MTLTexture (zero-copy via IOSurface)
        guard let outputTexture = makeTexture(
            from: outputBuffer,
            cache: textureCache
        ) else {
            return nil
        }

        // Run the spatial scaler into the private texture, then blit to the
        // IOSurface-backed shared texture for AVSampleBufferDisplayLayer.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        scaler.colorTexture = inputTexture
        scaler.outputTexture = privateOutput
        scaler.encode(commandBuffer: commandBuffer)

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blitEncoder.copy(
            from: privateOutput, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: needed.outputWidth, height: needed.outputHeight, depth: 1),
            to: outputTexture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            MirageLogger.error(.renderer, "MetalFX upscaler: command buffer failed")
            return nil
        }

        // Copy color space attachments from input to output
        copyBufferAttachments(from: inputBuffer, to: outputBuffer)

        return outputBuffer
    }

    // MARK: - Async Submission

    /// Submit a decoded frame for async upscaling. Never blocks the caller.
    /// Uses a "latest frame wins" policy — if a new frame arrives while the
    /// previous one is being upscaled, the older pending frame is discarded.
    func submitFrame(
        _ buffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        presentationTime: CMTime,
        streamID: StreamID
    ) {
        os_unfair_lock_lock(&pendingFrameLock)
        pendingFrame = PendingFrame(
            buffer: buffer,
            contentRect: contentRect,
            decodeTime: decodeTime,
            presentationTime: presentationTime,
            streamID: streamID
        )
        let shouldStart = !isProcessing
        if shouldStart { isProcessing = true }
        os_unfair_lock_unlock(&pendingFrameLock)

        if shouldStart {
            upscaleQueue.async { [weak self] in self?.processLoop() }
        }
    }

    /// Runs on the dedicated upscale queue. Loops until no pending frame remains,
    /// always grabbing the latest frame at each iteration.
    private func processLoop() {
        while true {
            os_unfair_lock_lock(&pendingFrameLock)
            guard let frame = pendingFrame else {
                isProcessing = false
                os_unfair_lock_unlock(&pendingFrameLock)
                return
            }
            pendingFrame = nil
            os_unfair_lock_unlock(&pendingFrameLock)

            var finalBuffer = frame.buffer
            var finalContentRect = frame.contentRect
            if let upscaled = upscale(frame.buffer) {
                let inW = CGFloat(CVPixelBufferGetWidth(frame.buffer))
                let inH = CGFloat(CVPixelBufferGetHeight(frame.buffer))
                let outW = CGFloat(CVPixelBufferGetWidth(upscaled))
                let outH = CGFloat(CVPixelBufferGetHeight(upscaled))
                if inW > 0, inH > 0 {
                    finalContentRect = CGRect(
                        x: frame.contentRect.origin.x * (outW / inW),
                        y: frame.contentRect.origin.y * (outH / inH),
                        width: frame.contentRect.size.width * (outW / inW),
                        height: frame.contentRect.size.height * (outH / inH)
                    )
                }
                finalBuffer = upscaled
            }

            MirageFrameCache.shared.store(
                finalBuffer,
                contentRect: finalContentRect,
                decodeTime: frame.decodeTime,
                presentationTime: frame.presentationTime,
                metalTexture: nil,
                texture: nil,
                for: frame.streamID
            )
        }
    }

    func invalidate() {
        os_unfair_lock_lock(&pendingFrameLock)
        pendingFrame = nil
        os_unfair_lock_unlock(&pendingFrameLock)

        // Wait for any in-flight processLoop iteration to finish before
        // releasing Metal resources.
        upscaleQueue.sync(flags: .barrier) {}

        spatialScaler = nil
        privateOutputTexture = nil
        outputPool = nil
        currentConfig = nil
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        if let transferSession {
            VTPixelTransferSessionInvalidate(transferSession)
        }
        transferSession = nil
        conversionPool = nil
        conversionPoolDimensions = (0, 0)
        loggedFallbackConversion = false
    }

    // MARK: - Private Helpers

    private func convertToBGRA(_ sourceBuffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        // Lazily create the transfer session
        if transferSession == nil {
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            guard status == noErr, let session else {
                MirageLogger.error(.renderer, "MetalFX upscaler: failed to create pixel transfer session (\(status))")
                return nil
            }
            transferSession = session
        }

        // Lazily create or resize the BGRA conversion pool
        if conversionPool == nil || conversionPoolDimensions != (width, height) {
            let poolAttributes: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 2,
            ]
            let pixelAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, pixelAttributes as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else {
                MirageLogger.error(.renderer, "MetalFX upscaler: failed to create conversion pool (\(status))")
                return nil
            }
            conversionPool = pool
            conversionPoolDimensions = (width, height)
        }

        guard let pool = conversionPool, let session = transferSession else { return nil }

        var destinationBuffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destinationBuffer)
        guard poolStatus == kCVReturnSuccess, let destinationBuffer else {
            MirageLogger.error(.renderer, "MetalFX upscaler: conversion pool exhausted")
            return nil
        }

        let transferStatus = VTPixelTransferSessionTransferImage(session, from: sourceBuffer, to: destinationBuffer)
        guard transferStatus == noErr else {
            MirageLogger.error(.renderer, "MetalFX upscaler: pixel transfer failed (\(transferStatus))")
            return nil
        }

        if !loggedFallbackConversion {
            loggedFallbackConversion = true
            let sourceName = VideoDecoder.pixelFormatName(CVPixelBufferGetPixelFormatType(sourceBuffer))
            MirageLogger.renderer(
                "MetalFX upscaler: using fallback YUV→BGRA conversion (decoder output is \(sourceName))"
            )
        }

        // Carry over color space attachments
        copyBufferAttachments(from: sourceBuffer, to: destinationBuffer)

        return destinationBuffer
    }

    private func createOutputPool(config: Configuration) -> CVPixelBufferPool? {
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4,
        ]
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: config.pixelFormat,
            kCVPixelBufferWidthKey: config.outputWidth,
            kCVPixelBufferHeightKey: config.outputHeight,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil,
            poolAttributes as CFDictionary,
            pixelAttributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess else { return nil }
        return pool
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = Self.metalPixelFormat(for: CVPixelBufferGetPixelFormatType(pixelBuffer))
        guard format != .invalid else { return nil }

        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            0,
            &textureRef
        )
        guard status == kCVReturnSuccess, let textureRef else { return nil }
        return CVMetalTextureGetTexture(textureRef)
    }

    private func copyBufferAttachments(from source: CVBuffer, to destination: CVBuffer) {
        if let propagated = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(destination, propagated, .shouldPropagate)
        }
        if let nonPropagated = CVBufferCopyAttachments(source, .shouldNotPropagate) {
            CVBufferSetAttachments(destination, nonPropagated, .shouldNotPropagate)
        }
    }

    private static func metalPixelFormat(for cvFormat: OSType) -> MTLPixelFormat {
        switch cvFormat {
        case kCVPixelFormatType_32BGRA:
            .bgra8Unorm
        case kCVPixelFormatType_ARGB2101010LEPacked:
            .bgr10a2Unorm
        default:
            .invalid
        }
    }
}

#endif
