//
//  MirageCodecBenchmark.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Local codec benchmarking helpers for connection quality diagnostics.
//

import CoreMedia
import Foundation
import MirageKit

enum MirageCodecBenchmark {
    static let benchmarkWidth = MirageCodecBenchmarkConstants.benchmarkWidth
    static let benchmarkHeight = MirageCodecBenchmarkConstants.benchmarkHeight
    static let benchmarkFrameRate = MirageCodecBenchmarkConstants.benchmarkFrameRate
    static let benchmarkFrameCount = MirageCodecBenchmarkConstants.benchmarkFrameCount

    static func runEncodeBenchmark() async throws -> Double {
        try await MirageCodecBenchmarkRunner.runEncodeBenchmark()
    }

    static func runDecodeBenchmark() async throws -> Double {
        try await MirageCodecBenchmarkRunner.runDecodeBenchmark()
    }

    static func runDecodeProbe(
        width: Int,
        height: Int,
        frameRate: Int,
        pixelFormat: MiragePixelFormat,
        frameCount: Int = 45
    ) async throws -> Double {
        let probeFormat = MirageCodecBenchmarkRunner.benchmarkPixelFormat(for: pixelFormat)
        let encoder = BenchmarkEncoder(
            width: width,
            height: height,
            frameRate: frameRate,
            pixelFormat: probeFormat
        )
        let encoded = try await encoder.encodeFrames(frameCount: frameCount, collectSamples: true)
        guard let firstSample = encoded.samples.first,
              let formatDescription = CMSampleBufferGetFormatDescription(firstSample) else {
            throw MirageError.protocolError("Failed to create sample buffers for decode probe")
        }

        let decodeTimes = try await BenchmarkDecoder.decodeSamples(
            encoded.samples,
            formatDescription: formatDescription
        )
        let trimmed = decodeTimes.dropFirst(5)
        return MirageCodecBenchmarkRunner.average(Array(trimmed))
    }
}
