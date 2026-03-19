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
import MirageKit
import VideoToolbox

enum MirageCodecBenchmark {
    static let benchmarkWidth = MirageCodecBenchmarkConstants.benchmarkWidth
    static let benchmarkHeight = MirageCodecBenchmarkConstants.benchmarkHeight
    static let benchmarkFrameRate = MirageCodecBenchmarkConstants.benchmarkFrameRate
    static let benchmarkFrameCount = MirageCodecBenchmarkConstants.benchmarkFrameCount

    static func runEncodeBenchmark() async throws -> Double {
        #if os(macOS)
        try await runEncoderThroughputBenchmark()
        #else
        try await MirageCodecBenchmarkRunner.runEncodeBenchmark()
        #endif
    }

    static func runDecodeBenchmark() async throws -> Double {
        try await MirageCodecBenchmarkRunner.runDecodeBenchmark()
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
            pixelFormat: MirageCodecBenchmarkRunner.benchmarkPixelFormat(for: pixelFormat)
        )
        let result = try await encoder.encodeFrames(frameCount: frameCount, collectSamples: false)
        let trimmed = result.encodeTimes.dropFirst(5)
        return MirageCodecBenchmarkRunner.average(Array(trimmed))
        #endif
    }

    // MARK: - macOS HEVCEncoder Benchmarks

    #if os(macOS)
    private static func runEncoderThroughputBenchmark() async throws -> Double {
        let targetBitrate = benchmarkBitrateBps(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let config = MirageEncoderConfiguration(
            targetFrameRate: benchmarkFrameRate,
            keyFrameInterval: benchmarkFrameRate * 30,
            colorDepth: .pro,
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
                let waitResult = await MirageCodecBenchmarkRunner.waitForGroup(group, timeout: .seconds(2))
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

        return MirageCodecBenchmarkRunner.average(encodeTimes)
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
            colorDepth: isTenBit(effectivePixelFormat) ? .pro : .standard,
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
        let pixelBufferFormat = MirageCodecBenchmarkRunner.benchmarkPixelFormat(for: effectivePixelFormat)

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
                let waitResult = await MirageCodecBenchmarkRunner.waitForGroup(group, timeout: .seconds(2))
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

        return MirageCodecBenchmarkRunner.average(encodeTimes)
    }

    // MARK: - Host-Specific Helpers

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
        case .p010, .nv12, .xf44, .ayuv16:
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

    private static func isTenBit(_ format: MiragePixelFormat) -> Bool {
        switch format {
        case .xf44, .ayuv16, .p010, .bgr10a2:
            true
        case .bgra8, .nv12:
            false
        }
    }
    #endif
}
