//
//  CaptureFrameCopier.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import CoreMedia
import CoreVideo
import Foundation
import MirageKit
#if os(macOS)
import Metal
#endif

#if os(macOS)

/// Copies SCK pixel buffers into owned CVPixelBuffers to release SCK buffers quickly.
final class CaptureFrameCopier: @unchecked Sendable {
    enum CopyResult {
        case copied(CVPixelBuffer)
        case poolExhausted
        case unsupported
    }

    enum ScheduleResult {
        case scheduled
        case inFlightLimit
        case poolExhausted
        case unsupported
    }

    private struct PoolConfig: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let minimumBufferCount: Int
    }

    private struct CopyTelemetry {
        var copyAttempts: UInt64 = 0
        var copySuccesses: UInt64 = 0
        var metalCopies: UInt64 = 0
        var cpuCopies: UInt64 = 0
        var copyFailures: UInt64 = 0
        var inFlightLimitDrops: UInt64 = 0
        var poolFailures: UInt64 = 0
        var bufferFailures: UInt64 = 0
        var durationTotalMs: Double = 0
        var durationMaxMs: Double = 0

        var hasData: Bool { copyAttempts > 0 || inFlightLimitDrops > 0 || poolFailures > 0 || bufferFailures > 0 }
    }

    private struct CopyContext: @unchecked Sendable {
        let source: CVPixelBuffer
        let destination: CVPixelBuffer
    }

    private enum MetalCopyFormat {
        case single(MTLPixelFormat)
        case biPlanar(luma: MTLPixelFormat, chroma: MTLPixelFormat)
    }

    private let copyQueue = DispatchQueue(label: "com.mirage.capture.copy", qos: .userInteractive)
    private let inFlightLock = NSLock()
    private var inFlightCount = 0
    private var inFlightLimit = 4
    private let poolLock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolConfig: PoolConfig?
    private let telemetryLock = NSLock()
    private var telemetry = CopyTelemetry()
    private var lastTelemetryLogTime: CFAbsoluteTime = 0
    private let telemetryLogInterval: CFAbsoluteTime = 2.0
    private let metalLock = NSLock()
    private var metalDevice: MTLDevice?
    private var metalQueue: MTLCommandQueue?
    private var metalTextureCache: CVMetalTextureCache?

    init() {}

    func preparePool(width: Int, height: Int, pixelFormat: OSType, minimumBufferCount: Int) -> Bool {
        let config = PoolConfig(
            width: max(1, width),
            height: max(1, height),
            pixelFormat: pixelFormat,
            minimumBufferCount: max(1, minimumBufferCount)
        )
        return ensurePool(config: config)
    }

    func scheduleCopy(
        pixelBuffer source: CVPixelBuffer,
        minimumBufferCount: Int,
        inFlightLimit: Int,
        completion: @escaping @Sendable (CopyResult) -> Void
    )
    -> ScheduleResult {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)

        let config = PoolConfig(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            minimumBufferCount: max(1, minimumBufferCount)
        )
        guard ensurePool(config: config) else {
            recordPoolFailure()
            return .poolExhausted
        }

        poolLock.lock()
        let pool = pool
        poolLock.unlock()
        guard let pool else {
            recordPoolFailure()
            return .poolExhausted
        }

        guard reserveCopySlot(limit: max(1, inFlightLimit)) else {
            recordInFlightLimitDrop()
            return .inFlightLimit
        }

        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard status == kCVReturnSuccess, let destination else {
            releaseCopySlot()
            recordBufferFailure()
            return .poolExhausted
        }

        let context = CopyContext(source: source, destination: destination)
        let copyStartTime = CFAbsoluteTimeGetCurrent()
        if scheduleMetalCopy(
            source: context.source,
            destination: context.destination,
            startTime: copyStartTime,
            completion: completion
        ) {
            return .scheduled
        }
        copyQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let didCopy = self.copyPixelBufferCPU(source: context.source, destination: context.destination)
                let durationMs = (CFAbsoluteTimeGetCurrent() - copyStartTime) * 1000
                self.recordCopyCompletion(durationMs: durationMs, success: didCopy, usedMetal: false)
                self.releaseCopySlot()
                if didCopy { completion(.copied(context.destination)) } else {
                    completion(.unsupported)
                }
            }
        }
        return .scheduled
    }

    private func ensurePool(config: PoolConfig) -> Bool {
        poolLock.lock()
        defer { poolLock.unlock() }
        if poolConfig == config, pool != nil { return true }

        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: config.minimumBufferCount,
        ]
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: config.pixelFormat,
            kCVPixelBufferWidthKey: config.width,
            kCVPixelBufferHeightKey: config.height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil,
            poolAttributes as CFDictionary,
            pixelAttributes as CFDictionary,
            &newPool
        )
        guard status == kCVReturnSuccess, let newPool else { return false }

        pool = newPool
        poolConfig = config
        return true
    }

    private func reserveCopySlot(limit: Int) -> Bool {
        inFlightLock.lock()
        inFlightLimit = max(1, limit)
        guard inFlightCount < inFlightLimit else {
            inFlightLock.unlock()
            return false
        }
        inFlightCount += 1
        inFlightLock.unlock()
        return true
    }

    private func releaseCopySlot() {
        inFlightLock.lock()
        inFlightCount = max(0, inFlightCount - 1)
        inFlightLock.unlock()
    }

    private func scheduleMetalCopy(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        startTime: CFAbsoluteTime,
        completion: @escaping @Sendable (CopyResult) -> Void
    )
    -> Bool {
        guard ensureMetal() else { return false }
        guard let format = metalFormat(for: CVPixelBufferGetPixelFormatType(source)) else { return false }
        guard let commandQueue = metalQueue, let textureCache = metalTextureCache else { return false }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        let blits: [(source: MTLTexture, destination: MTLTexture)]

        switch format {
        case let .single(pixelFormat):
            guard planeCount == 0 else { return false }
            guard let srcTexture = makeTexture(
                from: source,
                pixelFormat: pixelFormat,
                planeIndex: 0,
                cache: textureCache
            ),
                let dstTexture = makeTexture(
                    from: destination,
                    pixelFormat: pixelFormat,
                    planeIndex: 0,
                    cache: textureCache
                ) else {
                return false
            }
            blits = [(source: srcTexture, destination: dstTexture)]

        case let .biPlanar(lumaFormat, chromaFormat):
            guard planeCount == 2 else { return false }
            guard let srcLuma = makeTexture(from: source, pixelFormat: lumaFormat, planeIndex: 0, cache: textureCache),
                  let dstLuma = makeTexture(
                      from: destination,
                      pixelFormat: lumaFormat,
                      planeIndex: 0,
                      cache: textureCache
                  ),
                  let srcChroma = makeTexture(
                      from: source,
                      pixelFormat: chromaFormat,
                      planeIndex: 1,
                      cache: textureCache
                  ),
                  let dstChroma = makeTexture(
                      from: destination,
                      pixelFormat: chromaFormat,
                      planeIndex: 1,
                      cache: textureCache
                  ) else {
                return false
            }
            blits = [
                (source: srcLuma, destination: dstLuma),
                (source: srcChroma, destination: dstChroma),
            ]
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder() else {
            return false
        }

        for blit in blits {
            encoder.copy(from: blit.source, to: blit.destination)
        }

        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            releaseCopySlot()
            if buffer.status == .completed {
                recordCopyCompletion(durationMs: durationMs, success: true, usedMetal: true)
                completion(.copied(destination))
            } else {
                recordCopyCompletion(durationMs: durationMs, success: false, usedMetal: true)
                completion(.unsupported)
            }
        }
        commandBuffer.commit()
        return true
    }

    private func recordInFlightLimitDrop() {
        telemetryLock.lock()
        telemetry.inFlightLimitDrops += 1
        telemetryLock.unlock()
        logTelemetryIfNeeded()
    }

    private func recordPoolFailure() {
        telemetryLock.lock()
        telemetry.poolFailures += 1
        telemetryLock.unlock()
        logTelemetryIfNeeded()
    }

    private func recordBufferFailure() {
        telemetryLock.lock()
        telemetry.bufferFailures += 1
        telemetryLock.unlock()
        logTelemetryIfNeeded()
    }

    private func recordCopyCompletion(durationMs: Double, success: Bool, usedMetal: Bool) {
        telemetryLock.lock()
        telemetry.copyAttempts += 1
        if usedMetal { telemetry.metalCopies += 1 } else {
            telemetry.cpuCopies += 1
        }
        if success {
            telemetry.copySuccesses += 1
            telemetry.durationTotalMs += durationMs
            telemetry.durationMaxMs = max(telemetry.durationMaxMs, durationMs)
        } else {
            telemetry.copyFailures += 1
        }
        telemetryLock.unlock()
        logTelemetryIfNeeded()
    }

    private func logTelemetryIfNeeded() {
        guard MirageLogger.isEnabled(.capture) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        telemetryLock.lock()
        guard now - lastTelemetryLogTime >= telemetryLogInterval, telemetry.hasData else {
            telemetryLock.unlock()
            return
        }
        let snapshot = telemetry
        telemetry = CopyTelemetry()
        lastTelemetryLogTime = now
        telemetryLock.unlock()

        let averageMs = snapshot.copySuccesses > 0
            ? snapshot.durationTotalMs / Double(snapshot.copySuccesses)
            : 0
        let (inFlightCount, inFlightLimit) = inFlightSnapshot()
        MirageLogger.capture(
            "Capture copy telemetry: attempts=\(snapshot.copyAttempts) ok=\(snapshot.copySuccesses) fail=\(snapshot.copyFailures) " +
                "avg=\(averageMs.formatted(.number.precision(.fractionLength(1))))ms " +
                "max=\(snapshot.durationMaxMs.formatted(.number.precision(.fractionLength(1))))ms " +
                "metal=\(snapshot.metalCopies) cpu=\(snapshot.cpuCopies) " +
                "inFlightDrops=\(snapshot.inFlightLimitDrops) poolFailures=\(snapshot.poolFailures) " +
                "bufferFailures=\(snapshot.bufferFailures) inFlight=\(inFlightCount)/\(inFlightLimit)"
        )
    }

    private func inFlightSnapshot() -> (Int, Int) {
        inFlightLock.lock()
        let count = inFlightCount
        let limit = inFlightLimit
        inFlightLock.unlock()
        return (count, limit)
    }

    private func copyPixelBufferCPU(source: CVPixelBuffer, destination: CVPixelBuffer) -> Bool {
        let srcLock = CVPixelBufferLockBaseAddress(source, .readOnly)
        let dstLock = CVPixelBufferLockBaseAddress(destination, [])
        guard srcLock == kCVReturnSuccess, dstLock == kCVReturnSuccess else {
            if srcLock == kCVReturnSuccess { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
            if dstLock == kCVReturnSuccess { CVPixelBufferUnlockBaseAddress(destination, []) }
            return false
        }

        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount == 0 {
            guard let srcBase = CVPixelBufferGetBaseAddress(source),
                  let dstBase = CVPixelBufferGetBaseAddress(destination) else {
                return false
            }
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let dstBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
            let height = CVPixelBufferGetHeight(source)
            let copyBytes = min(srcBytesPerRow, dstBytesPerRow)

            for row in 0 ..< height {
                let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
                let dstRow = dstBase.advanced(by: row * dstBytesPerRow)
                memcpy(dstRow, srcRow, copyBytes)
            }
            return true
        }

        for planeIndex in 0 ..< planeCount {
            guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(source, planeIndex),
                  let dstBase = CVPixelBufferGetBaseAddressOfPlane(destination, planeIndex) else {
                return false
            }
            let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, planeIndex)
            let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, planeIndex)
            let height = CVPixelBufferGetHeightOfPlane(source, planeIndex)
            let copyBytes = min(srcBytesPerRow, dstBytesPerRow)

            for row in 0 ..< height {
                let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
                let dstRow = dstBase.advanced(by: row * dstBytesPerRow)
                memcpy(dstRow, srcRow, copyBytes)
            }
        }

        return true
    }

    private func ensureMetal() -> Bool {
        metalLock.lock()
        defer { metalLock.unlock() }
        if metalDevice != nil, metalQueue != nil, metalTextureCache != nil { return true }

        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        guard let queue = device.makeCommandQueue() else { return false }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let createdCache = cache else { return false }

        metalDevice = device
        metalQueue = queue
        metalTextureCache = createdCache
        return true
    }

    private func metalFormat(for pixelFormat: OSType) -> MetalCopyFormat? {
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            .single(.bgra8Unorm)
        case kCVPixelFormatType_ARGB2101010LEPacked:
            .single(.bgr10a2Unorm)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            .biPlanar(luma: .r8Unorm, chroma: .rg8Unorm)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            .biPlanar(luma: .r16Unorm, chroma: .rg16Unorm)
        default:
            nil
        }
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        planeIndex: Int,
        cache: CVMetalTextureCache
    )
    -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &textureRef
        )
        guard status == kCVReturnSuccess, let textureRef else { return nil }
        return CVMetalTextureGetTexture(textureRef)
    }
}

#endif
