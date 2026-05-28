//
//  MirageCodecBenchmark.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Local codec benchmarking helpers for connection quality diagnostics.
//

import CoreMedia
import CoreVideo
import Foundation
import MirageKit
import VideoToolbox

enum MirageCodecBenchmark {
    static func runEncodeBenchmark() async throws -> Double {
        let benchmarkWidth = MirageCodecBenchmarkConstants.benchmarkWidth
        let benchmarkHeight = MirageCodecBenchmarkConstants.benchmarkHeight
        let benchmarkFrameRate = MirageCodecBenchmarkConstants.benchmarkFrameRate
        let pixelsPerSecond = Double(benchmarkWidth * benchmarkHeight * benchmarkFrameRate)
        let targetBitrate = max(20_000_000, Int(pixelsPerSecond * 0.18))
        let config = MirageEncoderConfiguration(
            targetFrameRate: benchmarkFrameRate,
            keyFrameInterval: benchmarkFrameRate * 30,
            colorDepth: .pro,
            colorSpace: .displayP3,
            pixelFormat: .p010,
            bitrate: targetBitrate
        )
        let encoder = VideoEncoder(
            configuration: config,
            latencyMode: .lowestLatency,
            inFlightLimit: 1
        )
        try await encoder.createSession(width: benchmarkWidth, height: benchmarkHeight)
        _ = try await encoder.preheat()

        let group = DispatchGroup()
        await encoder.startEncoding(
            onEncodedFrame: { _, _, _, finishFrame in finishFrame() },
            onFrameComplete: { group.leave() }
        )

        let duration = CMTime(value: 1, timescale: CMTimeScale(benchmarkFrameRate))
        let frameInfo = CapturedFrameInfo(
            contentRect: CGRect(x: 0, y: 0, width: CGFloat(benchmarkWidth), height: CGFloat(benchmarkHeight)),
            dirtyPercentage: 100,
            isIdleFrame: false
        )

        var encodeTimes: [Double] = []

        for frameIndex in 0 ..< MirageCodecBenchmarkConstants.benchmarkFrameCount {
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

    // MARK: - Host-Specific Helpers

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

}
