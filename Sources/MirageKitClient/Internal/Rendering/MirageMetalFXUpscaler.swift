//
//  MirageMetalFXUpscaler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/18/26.
//
//  MetalFX spatial (and future temporal) upscaler that operates on
//  IOSurface-backed CVPixelBuffers and feeds the result back through
//  the existing AVSampleBufferDisplayLayer path.
//

#if canImport(MetalFX)
import CoreVideo
import Foundation
import Metal
import MetalFX
import MirageKit

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
    private var outputPool: CVPixelBufferPool?
    private var currentConfig: Configuration?

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
            MirageLogger.error(.renderer, "MetalFX upscaler: unsupported pixel format \(config.pixelFormat)")
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

        spatialScaler = scaler
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
        let pixelFormat = CVPixelBufferGetPixelFormatType(inputBuffer)

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
              let pool = outputPool,
              let textureCache else {
            return nil
        }

        // Wrap input as MTLTexture (zero-copy via IOSurface)
        guard let inputTexture = makeTexture(
            from: inputBuffer,
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

        // Run the spatial scaler
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        scaler.colorTexture = inputTexture
        scaler.outputTexture = outputTexture
        scaler.encode(commandBuffer: commandBuffer)

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

    func invalidate() {
        spatialScaler = nil
        outputPool = nil
        currentConfig = nil
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }

    // MARK: - Private Helpers

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
