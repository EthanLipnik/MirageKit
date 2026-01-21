import CoreMedia
import CoreVideo
import Foundation
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
        case poolExhausted
        case unsupported
    }

    private struct PoolConfig: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let minimumBufferCount: Int
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
    private let metalLock = NSLock()
    private var metalDevice: MTLDevice?
    private var metalQueue: MTLCommandQueue?
    private var metalTextureCache: CVMetalTextureCache?

    init() {}

    func scheduleCopy(
        pixelBuffer source: CVPixelBuffer,
        minimumBufferCount: Int,
        inFlightLimit: Int,
        completion: @escaping @Sendable (CopyResult) -> Void
    ) -> ScheduleResult {
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
            return .poolExhausted
        }

        poolLock.lock()
        let pool = self.pool
        poolLock.unlock()
        guard let pool else {
            return .poolExhausted
        }

        guard reserveCopySlot(limit: max(1, inFlightLimit)) else {
            return .poolExhausted
        }

        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard status == kCVReturnSuccess, let destination else {
            releaseCopySlot()
            return .poolExhausted
        }

        let context = CopyContext(source: source, destination: destination)
        copyQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let didCopy = self.copyPixelBuffer(source: context.source, destination: context.destination)
                self.releaseCopySlot()
                if didCopy {
                    completion(.copied(context.destination))
                } else {
                    completion(.unsupported)
                }
            }
        }
        return .scheduled
    }

    private func ensurePool(config: PoolConfig) -> Bool {
        poolLock.lock()
        defer { poolLock.unlock() }
        if poolConfig == config, pool != nil {
            return true
        }

        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: config.minimumBufferCount
        ]
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: config.pixelFormat,
            kCVPixelBufferWidthKey: config.width,
            kCVPixelBufferHeightKey: config.height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, pixelAttributes as CFDictionary, &newPool)
        guard status == kCVReturnSuccess, let newPool else {
            return false
        }

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


    private func copyPixelBuffer(source: CVPixelBuffer, destination: CVPixelBuffer) -> Bool {
        if copyPixelBufferWithMetal(source: source, destination: destination) {
            return true
        }
        let srcLock = CVPixelBufferLockBaseAddress(source, .readOnly)
        let dstLock = CVPixelBufferLockBaseAddress(destination, [])
        guard srcLock == kCVReturnSuccess, dstLock == kCVReturnSuccess else {
            if srcLock == kCVReturnSuccess {
                CVPixelBufferUnlockBaseAddress(source, .readOnly)
            }
            if dstLock == kCVReturnSuccess {
                CVPixelBufferUnlockBaseAddress(destination, [])
            }
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

            for row in 0..<height {
                let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
                let dstRow = dstBase.advanced(by: row * dstBytesPerRow)
                memcpy(dstRow, srcRow, copyBytes)
            }
            return true
        }

        for planeIndex in 0..<planeCount {
            guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(source, planeIndex),
                  let dstBase = CVPixelBufferGetBaseAddressOfPlane(destination, planeIndex) else {
                return false
            }
            let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, planeIndex)
            let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, planeIndex)
            let height = CVPixelBufferGetHeightOfPlane(source, planeIndex)
            let copyBytes = min(srcBytesPerRow, dstBytesPerRow)

            for row in 0..<height {
                let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
                let dstRow = dstBase.advanced(by: row * dstBytesPerRow)
                memcpy(dstRow, srcRow, copyBytes)
            }
        }

        return true
    }

    private func copyPixelBufferWithMetal(source: CVPixelBuffer, destination: CVPixelBuffer) -> Bool {
        guard ensureMetal() else { return false }
        guard let format = metalFormat(for: CVPixelBufferGetPixelFormatType(source)) else { return false }
        guard let commandQueue = metalQueue, let textureCache = metalTextureCache else { return false }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        switch format {
        case .single(let pixelFormat):
            guard planeCount == 0 else { return false }
            guard let srcTexture = makeTexture(from: source, pixelFormat: pixelFormat, planeIndex: 0, cache: textureCache),
                  let dstTexture = makeTexture(from: destination, pixelFormat: pixelFormat, planeIndex: 0, cache: textureCache) else {
                return false
            }
            return blitCopy(from: srcTexture, to: dstTexture, queue: commandQueue)

        case .biPlanar(let lumaFormat, let chromaFormat):
            guard planeCount == 2 else { return false }
            guard let srcLuma = makeTexture(from: source, pixelFormat: lumaFormat, planeIndex: 0, cache: textureCache),
                  let dstLuma = makeTexture(from: destination, pixelFormat: lumaFormat, planeIndex: 0, cache: textureCache),
                  let srcChroma = makeTexture(from: source, pixelFormat: chromaFormat, planeIndex: 1, cache: textureCache),
                  let dstChroma = makeTexture(from: destination, pixelFormat: chromaFormat, planeIndex: 1, cache: textureCache) else {
                return false
            }

            guard blitCopy(from: srcLuma, to: dstLuma, queue: commandQueue) else { return false }
            return blitCopy(from: srcChroma, to: dstChroma, queue: commandQueue)
        }
    }

    private func ensureMetal() -> Bool {
        metalLock.lock()
        defer { metalLock.unlock() }
        if metalDevice != nil, metalQueue != nil, metalTextureCache != nil {
            return true
        }

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
            return .single(.bgra8Unorm)
        case kCVPixelFormatType_ARGB2101010LEPacked:
            return .single(.bgr10a2Unorm)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return .biPlanar(luma: .r8Unorm, chroma: .rg8Unorm)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return .biPlanar(luma: .r16Unorm, chroma: .rg16Unorm)
        default:
            return nil
        }
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        planeIndex: Int,
        cache: CVMetalTextureCache
    ) -> MTLTexture? {
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

    private func blitCopy(from source: MTLTexture, to destination: MTLTexture, queue: MTLCommandQueue) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder() else {
            return false
        }
        encoder.copy(from: source, to: destination)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }
}

#endif
