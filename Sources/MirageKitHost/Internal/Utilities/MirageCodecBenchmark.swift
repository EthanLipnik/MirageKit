//
//  MirageCodecBenchmark.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Local codec benchmarking helpers for automatic quality.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import MirageKit

enum MirageCodecBenchmark {
    static let benchmarkWidth = 1920
    static let benchmarkHeight = 1080
    static let benchmarkFrameRate = 60
    static let benchmarkFrameCount = 120

    static func runEncodeBenchmark() async throws -> Double {
        #if os(macOS)
        try await runEncoderThroughputBenchmark()
        #else
        let encoder = BenchmarkEncoder(
            width: benchmarkWidth,
            height: benchmarkHeight,
            frameRate: benchmarkFrameRate,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        let result = try await encoder.encodeFrames(frameCount: benchmarkFrameCount, collectSamples: false)
        let trimmed = result.encodeTimes.dropFirst(5)
        return average(Array(trimmed))
        #endif
    }

    static func runDecodeBenchmark() async throws -> Double {
        let encoder = BenchmarkEncoder(
            width: benchmarkWidth,
            height: benchmarkHeight,
            frameRate: benchmarkFrameRate,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        let encoded = try await encoder.encodeFrames(frameCount: benchmarkFrameCount, collectSamples: true)
        guard let firstSample = encoded.samples.first,
              let formatDescription = CMSampleBufferGetFormatDescription(firstSample) else {
            throw MirageError.protocolError("Failed to create sample buffers for decode benchmark")
        }

        let decodeTimes = try await BenchmarkDecoder.decodeSamples(
            encoded.samples,
            formatDescription: formatDescription
        )
        return average(decodeTimes)
    }

    static func runEncodeProbe(
        width: Int,
        height: Int,
        frameRate: Int,
        pixelFormat: MiragePixelFormat,
        frameCount: Int = 45
    ) async throws -> Double {
        let sanitizedFrameRate = max(1, frameRate)
        #if os(macOS)
        return try await runEncoderThroughputProbe(
            width: width,
            height: height,
            frameRate: sanitizedFrameRate,
            pixelFormat: pixelFormat,
            frameCount: frameCount
        )
        #else
        let encoder = BenchmarkEncoder(
            width: width,
            height: height,
            frameRate: sanitizedFrameRate,
            pixelFormat: benchmarkPixelFormat(for: pixelFormat)
        )
        let result = try await encoder.encodeFrames(frameCount: frameCount, collectSamples: false)
        let trimmed = result.encodeTimes.dropFirst(5)
        return average(Array(trimmed))
        #endif
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let total = values.reduce(0, +)
        return total / Double(values.count)
    }

    #if os(macOS)
    private static func runEncoderThroughputBenchmark() async throws -> Double {
        let targetBitrate = benchmarkBitrateBps(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let config = MirageEncoderConfiguration(
            targetFrameRate: benchmarkFrameRate,
            keyFrameInterval: benchmarkFrameRate * 30,
            colorSpace: .displayP3,
            pixelFormat: .p010,
            bitrate: targetBitrate
        )
        let encoder = HEVCEncoder(
            configuration: config,
            latencyMode: .lowestLatency,
            inFlightLimit: 1
        )
        try await encoder.createSession(width: benchmarkWidth, height: benchmarkHeight)
        try await encoder.preheat()

        let group = DispatchGroup()
        await encoder.startEncoding(
            onEncodedFrame: { _, _, _ in },
            onFrameComplete: { group.leave() }
        )

        let duration = CMTime(value: 1, timescale: CMTimeScale(benchmarkFrameRate))
        let frameInfo = CapturedFrameInfo(
            contentRect: CGRect(x: 0, y: 0, width: CGFloat(benchmarkWidth), height: CGFloat(benchmarkHeight)),
            dirtyPercentage: 100,
            isIdleFrame: false
        )

        var encodeTimes: [Double] = []

        for frameIndex in 0 ..< benchmarkFrameCount {
            guard let pixelBuffer = makeBenchmarkPixelBuffer(
                width: benchmarkWidth,
                height: benchmarkHeight,
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                frameIndex: frameIndex
            ) else {
                throw MirageError.protocolError("Encode benchmark failed: pixel buffer unavailable")
            }

            let presentationTime = CMTime(
                value: CMTimeValue(frameIndex),
                timescale: CMTimeScale(benchmarkFrameRate)
            )
            let frame = CapturedFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                duration: duration,
                captureTime: CFAbsoluteTimeGetCurrent(),
                info: frameInfo
            )

            group.enter()
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try await encoder.encodeFrame(frame, forceKeyframe: frameIndex == 0)
            switch result {
            case .accepted:
                let waitResult = await waitForGroup(group, timeout: .seconds(2))
                if waitResult == .timedOut {
                    throw MirageError.protocolError("Encode benchmark timed out")
                }
                let deltaMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                if frameIndex >= 5 {
                    encodeTimes.append(deltaMs)
                }
            case .skipped:
                group.leave()
            }
        }

        await encoder.stopEncoding()

        guard !encodeTimes.isEmpty else {
            throw MirageError.protocolError("Encode benchmark failed: no samples")
        }

        return average(encodeTimes)
    }

    private static func runEncoderThroughputProbe(
        width: Int,
        height: Int,
        frameRate: Int,
        pixelFormat: MiragePixelFormat,
        frameCount: Int
    ) async throws -> Double {
        let effectivePixelFormat = probePixelFormat(for: pixelFormat)
        let colorSpace: MirageColorSpace = isTenBit(pixelFormat) ? .displayP3 : .sRGB
        let targetBitrate = probeBitrateBps(
            width: width,
            height: height,
            frameRate: frameRate,
            pixelFormat: effectivePixelFormat
        )
        let config = MirageEncoderConfiguration(
            targetFrameRate: frameRate,
            keyFrameInterval: frameRate * 2,
            colorSpace: colorSpace,
            pixelFormat: effectivePixelFormat,
            bitrate: targetBitrate
        )
        let encoder = HEVCEncoder(
            configuration: config,
            latencyMode: .lowestLatency,
            inFlightLimit: 1
        )
        try await encoder.createSession(width: width, height: height)
        try await encoder.preheat()

        let group = DispatchGroup()
        await encoder.startEncoding(
            onEncodedFrame: { _, _, _ in },
            onFrameComplete: { group.leave() }
        )

        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let frameInfo = CapturedFrameInfo(
            contentRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            dirtyPercentage: 100,
            isIdleFrame: false
        )
        let pixelBufferFormat = benchmarkPixelFormat(for: effectivePixelFormat)

        var encodeTimes: [Double] = []

        for frameIndex in 0 ..< frameCount {
            guard let pixelBuffer = makeBenchmarkPixelBuffer(
                width: width,
                height: height,
                pixelFormat: pixelBufferFormat,
                frameIndex: frameIndex
            ) else {
                throw MirageError.protocolError("Encode probe failed: pixel buffer unavailable")
            }

            let presentationTime = CMTime(
                value: CMTimeValue(frameIndex),
                timescale: CMTimeScale(frameRate)
            )
            let frame = CapturedFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                duration: duration,
                captureTime: CFAbsoluteTimeGetCurrent(),
                info: frameInfo
            )

            group.enter()
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try await encoder.encodeFrame(frame, forceKeyframe: frameIndex == 0)
            switch result {
            case .accepted:
                let waitResult = await waitForGroup(group, timeout: .seconds(2))
                if waitResult == .timedOut {
                    throw MirageError.protocolError("Encode probe timed out")
                }
                let deltaMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                if frameIndex >= 5 {
                    encodeTimes.append(deltaMs)
                }
            case .skipped:
                group.leave()
            }
        }

        await encoder.stopEncoding()

        guard !encodeTimes.isEmpty else {
            throw MirageError.protocolError("Encode probe failed: no samples")
        }

        return average(encodeTimes)
    }

    private static func benchmarkBitrateBps(pixelFormat: OSType) -> Int {
        let targetBpp: Double = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ? 0.18 : 0.14
        let pixelsPerSecond = Double(benchmarkWidth * benchmarkHeight * benchmarkFrameRate)
        let target = Int(pixelsPerSecond * targetBpp)
        return max(20_000_000, target)
    }

    private static func probeBitrateBps(
        width: Int,
        height: Int,
        frameRate: Int,
        pixelFormat: MiragePixelFormat
    ) -> Int {
        let targetBpp: Double = isTenBit(pixelFormat) ? 0.18 : 0.14
        let pixelsPerSecond = Double(width * height * frameRate)
        let target = Int(pixelsPerSecond * targetBpp)
        return max(20_000_000, target)
    }

    private static func probePixelFormat(for format: MiragePixelFormat) -> MiragePixelFormat {
        switch format {
        case .p010, .nv12:
            return format
        case .bgr10a2:
            return .p010
        case .bgra8:
            return .nv12
        }
    }

    private static func makeBenchmarkPixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        frameIndex: Int
    ) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        let fillValue = UInt8((frameIndex * 13) % 255)

        if planeCount == 0 {
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                memset(baseAddress, Int32(fillValue), CVPixelBufferGetDataSize(buffer))
            }
        } else {
            for plane in 0 ..< planeCount {
                if let baseAddress = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                    let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
                    memset(baseAddress, Int32(fillValue), bytesPerRow * planeHeight)
                }
            }
        }

        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    #endif

    private final class BenchmarkEncoder {
        struct Result {
            var samples: [CMSampleBuffer]
            var encodeTimes: [Double]
        }

        let width: Int
        let height: Int
        let frameRate: Int
        let pixelFormat: OSType

        init(width: Int, height: Int, frameRate: Int, pixelFormat: OSType) {
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.pixelFormat = pixelFormat
        }

        func encodeFrames(frameCount: Int, collectSamples: Bool) async throws -> Result {
            var session: VTCompressionSession?
            let encoderSpecification: CFDictionary = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            ] as CFDictionary
            let imageBufferAttributes: CFDictionary = [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: encoderSpecification,
                imageBufferAttributes: imageBufferAttributes,
                compressedDataAllocator: nil,
                outputCallback: BenchmarkEncoder.encodeCallback,
                refcon: nil,
                compressionSessionOut: &session
            )

            guard status == noErr, let session else {
                throw MirageError.protocolError("Failed to create compression session")
            }

            defer {
                VTCompressionSessionInvalidate(session)
            }

            let profileLevel: CFString = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                ? kVTProfileLevel_HEVC_Main10_AutoLevel
                : kVTProfileLevel_HEVC_Main_AutoLevel
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFTypeRef)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFTypeRef)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: frameRate * 2 as CFTypeRef)
            let intervalSeconds = max(1.0, Double(frameRate * 2) / Double(frameRate))
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                value: intervalSeconds as CFTypeRef
            )
            let targetBpp: Double = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ? 0.12 : 0.10
            let targetBitrate = max(10_000_000, Int(Double(width * height * frameRate) * targetBpp))
            let bytesPerSecond = max(1, targetBitrate / 8)
            let rateLimits: [NSNumber] = [NSNumber(value: bytesPerSecond), 0.5]
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFTypeRef)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: rateLimits as CFArray)
            VTCompressionSessionPrepareToEncodeFrames(session)

            let group = DispatchGroup()
            let state = BenchmarkEncoderState(collectSamples: collectSamples, group: group)
            var encodeError: OSStatus?

            for frameIndex in 0 ..< frameCount {
                autoreleasepool {
                    guard let pixelBuffer = BenchmarkEncoder.makePixelBuffer(
                        width: width,
                        height: height,
                        pixelFormat: pixelFormat,
                        frameIndex: frameIndex
                    ) else {
                        encodeError = -1
                        return
                    }

                    group.enter()
                    let startTime = CFAbsoluteTimeGetCurrent()
                    let info = BenchmarkFrameInfo(startTime: startTime, state: state)
                    let unmanaged = Unmanaged.passRetained(info)
                    let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(frameRate))

                    let status = VTCompressionSessionEncodeFrame(
                        session,
                        imageBuffer: pixelBuffer,
                        presentationTimeStamp: presentationTime,
                        duration: .invalid,
                        frameProperties: nil,
                        sourceFrameRefcon: unmanaged.toOpaque(),
                        infoFlagsOut: nil
                    )

                    if status != noErr {
                        unmanaged.release()
                        encodeError = status
                        group.leave()
                    }
                }

                if encodeError != nil { break }
            }

            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

            let waitResult = await waitForGroup(group, timeout: .seconds(10))
            if waitResult == .timedOut {
                throw MirageError.protocolError("Encode benchmark timed out")
            }

            if let encodeError {
                throw MirageError.protocolError("Encode benchmark failed: \(encodeError)")
            }

            return Result(samples: state.samples, encodeTimes: state.encodeTimes)
        }

        private static let encodeCallback: VTCompressionOutputCallback = { _, sourceFrameRefCon, status, _, sampleBuffer in
            guard let sourceFrameRefCon else { return }
            let info = Unmanaged<BenchmarkFrameInfo>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
            let deltaMs = (CFAbsoluteTimeGetCurrent() - info.startTime) * 1000

            info.state.lock.lock()
            info.state.encodeTimes.append(deltaMs)
            if info.state.collectSamples, let sampleBuffer {
                info.state.samples.append(sampleBuffer)
            }
            info.state.lock.unlock()
            info.state.group.leave()

            if status != noErr {
                return
            }
        }

        private static func makePixelBuffer(
            width: Int,
            height: Int,
            pixelFormat: OSType,
            frameIndex: Int
        ) -> CVPixelBuffer? {
            let attrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                pixelFormat,
                attrs as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

            CVPixelBufferLockBaseAddress(buffer, [])
            let planeCount = CVPixelBufferGetPlaneCount(buffer)
            let fillValue = UInt8(frameIndex % 255)

            if planeCount == 0 {
                if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                    memset(baseAddress, Int32(fillValue), CVPixelBufferGetDataSize(buffer))
                }
            } else {
                for plane in 0 ..< planeCount {
                    if let baseAddress = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                        let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
                        memset(baseAddress, Int32(fillValue), bytesPerRow * planeHeight)
                    }
                }
            }

            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }
    }

    private enum BenchmarkDecoder {
        static func decodeSamples(
            _ samples: [CMSampleBuffer],
            formatDescription: CMFormatDescription
        ) async throws -> [Double] {
            var session: VTDecompressionSession?
            var callbackRecord = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: decodeCallback,
                decompressionOutputRefCon: nil
            )
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: nil,
                imageBufferAttributes: nil,
                outputCallback: &callbackRecord,
                decompressionSessionOut: &session
            )

            guard status == noErr, let session else {
                throw MirageError.protocolError("Failed to create decompression session")
            }

            defer {
                VTDecompressionSessionInvalidate(session)
            }

            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

            let group = DispatchGroup()
            let state = BenchmarkDecoderState(group: group)
            var decodeError: OSStatus?

            for sample in samples {
                group.enter()
                let startTime = CFAbsoluteTimeGetCurrent()
                let info = BenchmarkDecodeInfo(startTime: startTime, state: state)
                let unmanaged = Unmanaged.passRetained(info)
                let status = VTDecompressionSessionDecodeFrame(
                    session,
                    sampleBuffer: sample,
                    flags: [],
                    frameRefcon: unmanaged.toOpaque(),
                    infoFlagsOut: nil
                )
                if status != noErr {
                    unmanaged.release()
                    decodeError = status
                    group.leave()
                }
            }

            VTDecompressionSessionWaitForAsynchronousFrames(session)

            let waitResult = await waitForGroup(group, timeout: .seconds(10))
            if waitResult == .timedOut {
                throw MirageError.protocolError("Decode benchmark timed out")
            }

            if let decodeError {
                throw MirageError.protocolError("Decode benchmark failed: \(decodeError)")
            }

            return state.decodeTimes
        }

        private static let decodeCallback: VTDecompressionOutputCallback = { _, sourceFrameRefCon, status, _, _, _, _ in
            guard let sourceFrameRefCon else { return }
            let info = Unmanaged<BenchmarkDecodeInfo>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
            let deltaMs = (CFAbsoluteTimeGetCurrent() - info.startTime) * 1000

            info.state.lock.lock()
            info.state.decodeTimes.append(deltaMs)
            info.state.lock.unlock()
            info.state.group.leave()

            if status != noErr {
                return
            }
        }
    }

    private final class BenchmarkEncoderState {
        let lock = NSLock()
        let collectSamples: Bool
        let group: DispatchGroup
        var samples: [CMSampleBuffer] = []
        var encodeTimes: [Double] = []

        init(collectSamples: Bool, group: DispatchGroup) {
            self.collectSamples = collectSamples
            self.group = group
        }
    }

    private final class BenchmarkFrameInfo {
        let startTime: CFAbsoluteTime
        let state: BenchmarkEncoderState

        init(startTime: CFAbsoluteTime, state: BenchmarkEncoderState) {
            self.startTime = startTime
            self.state = state
        }
    }

    private final class BenchmarkDecoderState {
        let lock = NSLock()
        let group: DispatchGroup
        var decodeTimes: [Double] = []

        init(group: DispatchGroup) {
            self.group = group
        }
    }

    private final class BenchmarkDecodeInfo {
        let startTime: CFAbsoluteTime
        let state: BenchmarkDecoderState

        init(startTime: CFAbsoluteTime, state: BenchmarkDecoderState) {
            self.startTime = startTime
            self.state = state
        }
    }

    private static func waitForGroup(_ group: DispatchGroup, timeout: Duration) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = group.wait(timeout: .now() + timeout.timeInterval)
                continuation.resume(returning: result)
            }
        }
    }

    private static func benchmarkPixelFormat(for format: MiragePixelFormat) -> OSType {
        switch format {
        case .p010, .bgr10a2:
            return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .bgra8, .nv12:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }

    private static func isTenBit(_ format: MiragePixelFormat) -> Bool {
        switch format {
        case .p010, .bgr10a2:
            true
        case .bgra8, .nv12:
            false
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
