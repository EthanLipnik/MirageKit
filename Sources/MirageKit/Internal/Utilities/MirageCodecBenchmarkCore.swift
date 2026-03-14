//
//  MirageCodecBenchmarkCore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/14/26.
//
//  Shared codec benchmark infrastructure used by both host and client.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - Constants

package enum MirageCodecBenchmarkConstants {
    package static let benchmarkWidth = 1920
    package static let benchmarkHeight = 1080
    package static let benchmarkFrameRate = 60
    package static let benchmarkFrameCount = 120
}

// MARK: - Shared Benchmark Functions

package enum MirageCodecBenchmarkRunner {
    package static func runEncodeBenchmark(
        width: Int = MirageCodecBenchmarkConstants.benchmarkWidth,
        height: Int = MirageCodecBenchmarkConstants.benchmarkHeight,
        frameRate: Int = MirageCodecBenchmarkConstants.benchmarkFrameRate,
        frameCount: Int = MirageCodecBenchmarkConstants.benchmarkFrameCount,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ) async throws -> Double {
        let encoder = BenchmarkEncoder(
            width: width,
            height: height,
            frameRate: frameRate,
            pixelFormat: pixelFormat
        )
        let result = try await encoder.encodeFrames(frameCount: frameCount, collectSamples: false)
        let trimmed = result.encodeTimes.dropFirst(5)
        return average(Array(trimmed))
    }

    package static func runDecodeBenchmark(
        width: Int = MirageCodecBenchmarkConstants.benchmarkWidth,
        height: Int = MirageCodecBenchmarkConstants.benchmarkHeight,
        frameRate: Int = MirageCodecBenchmarkConstants.benchmarkFrameRate,
        frameCount: Int = MirageCodecBenchmarkConstants.benchmarkFrameCount,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ) async throws -> Double {
        let encoder = BenchmarkEncoder(
            width: width,
            height: height,
            frameRate: frameRate,
            pixelFormat: pixelFormat
        )
        let encoded = try await encoder.encodeFrames(frameCount: frameCount, collectSamples: true)
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

    package static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let total = values.reduce(0, +)
        return total / Double(values.count)
    }

    package static func benchmarkPixelFormat(for format: MiragePixelFormat) -> OSType {
        switch format {
        case .xf44:
            kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        case .p010, .bgr10a2:
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .bgra8, .nv12:
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }

    package static func waitForGroup(_ group: DispatchGroup, timeout: Duration) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = group.wait(timeout: .now() + timeout.timeInterval)
                continuation.resume(returning: result)
            }
        }
    }
}

// MARK: - Benchmark Encoder

package final class BenchmarkEncoder {
    package struct Result {
        package var samples: [CMSampleBuffer]
        package var encodeTimes: [Double]
    }

    let width: Int
    let height: Int
    let frameRate: Int
    let pixelFormat: OSType

    package init(width: Int, height: Int, frameRate: Int, pixelFormat: OSType) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.pixelFormat = pixelFormat
    }

    package func encodeFrames(frameCount: Int, collectSamples: Bool) async throws -> Result {
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

        let waitResult = await MirageCodecBenchmarkRunner.waitForGroup(group, timeout: .seconds(10))
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

// MARK: - Benchmark Decoder

package enum BenchmarkDecoder {
    package static func decodeSamples(
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

        let waitResult = await MirageCodecBenchmarkRunner.waitForGroup(group, timeout: .seconds(10))
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

// MARK: - State Classes

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

// MARK: - Duration Extension

package extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
