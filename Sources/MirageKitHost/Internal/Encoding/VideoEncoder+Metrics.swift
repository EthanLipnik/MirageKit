//
//  VideoEncoder+Metrics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC encoder extensions.
//

import CoreMedia
import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension EncodePerformanceTracker {
    func record(durationMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(durationMs)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
    }

    var averageMs: Double {
        let snapshot: [Double]
        lock.lock()
        do {
            defer { lock.unlock() }
            snapshot = samples
        }
        guard !snapshot.isEmpty else { return 0 }
        let total = snapshot.reduce(0, +)
        return total / Double(snapshot.count)
    }
}

/// Encoded-byte telemetry sampled from VideoToolbox output callbacks.
struct EncodedOutputTelemetrySnapshot: Sendable, Equatable {
    let requestedBitrateBps: Int?
    let actualBitrateBps: Int?
    let actualWindowMs: Int?
    let frameBytesP50: Int?
    let frameBytesP95: Int?
    let frameBytesP99: Int?
    let keyframeBytesP50: Int?
    let keyframeBytesP95: Int?
    let keyframeBytesP99: Int?
    let rateControlStrategy: MirageEncoderRateControlStrategy
    let rateLimitBytes: Int?
    let rateLimitWindowMs: Int?
}

/// Thread-safe rolling encoded-output tracker. VideoToolbox callbacks do not run on
/// the encoder actor, so this avoids actor hops on the realtime callback path.
final class EncodedOutputTelemetryTracker: @unchecked Sendable {
    private struct Sample {
        let timestamp: CFAbsoluteTime
        let byteCount: Int
        let isKeyframe: Bool
    }

    private let lock = NSLock()
    private let retentionSeconds: CFAbsoluteTime = 8.0
    private let defaultWindowSeconds: CFAbsoluteTime = 2.0
    private var samples: [Sample] = []
    private var requestedBitrateBps: Int?
    private var rateControlStrategy: MirageEncoderRateControlStrategy = .none
    private var rateLimitBytes: Int?
    private var rateLimitWindowSeconds: Double?

    func recordFrame(
        byteCount: Int,
        isKeyframe: Bool,
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(Sample(timestamp: timestamp, byteCount: byteCount, isKeyframe: isKeyframe))
        trimSamples(olderThan: timestamp - retentionSeconds)
    }

    func updateRateControl(
        requestedBitrateBps: Int?,
        strategy: MirageEncoderRateControlStrategy,
        rateLimit: (bytes: Int, windowSeconds: Double)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.requestedBitrateBps = requestedBitrateBps
        rateControlStrategy = strategy
        rateLimitBytes = rateLimit?.bytes
        rateLimitWindowSeconds = rateLimit?.windowSeconds
    }

    func snapshot(
        since startTime: CFAbsoluteTime? = nil,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> EncodedOutputTelemetrySnapshot {
        let snapshotSamples: [Sample]
        let requestedBitrate: Int?
        let strategy: MirageEncoderRateControlStrategy
        let limitBytes: Int?
        let limitWindowSeconds: Double?
        let lowerBound = startTime ?? (now - defaultWindowSeconds)

        lock.lock()
        do {
            trimSamples(olderThan: now - retentionSeconds)
            snapshotSamples = samples.filter { $0.timestamp >= lowerBound && $0.timestamp <= now }
            requestedBitrate = requestedBitrateBps
            strategy = rateControlStrategy
            limitBytes = rateLimitBytes
            limitWindowSeconds = rateLimitWindowSeconds
            lock.unlock()
        }

        let durationSeconds: Double
        if let startTime {
            durationSeconds = max(0.001, now - startTime)
        } else if let first = snapshotSamples.first {
            durationSeconds = max(0.001, now - first.timestamp)
        } else {
            durationSeconds = 0
        }
        let totalBytes = snapshotSamples.reduce(0) { $0 + $1.byteCount }
        let actualBitrate = durationSeconds > 0 && totalBytes > 0
            ? Int((Double(totalBytes) * 8.0 / durationSeconds).rounded())
            : nil
        let frameBytes = snapshotSamples.map(\.byteCount)
        let keyframeBytes = snapshotSamples.filter(\.isKeyframe).map(\.byteCount)

        return EncodedOutputTelemetrySnapshot(
            requestedBitrateBps: requestedBitrate,
            actualBitrateBps: actualBitrate,
            actualWindowMs: durationSeconds > 0 ? Int((durationSeconds * 1000.0).rounded()) : nil,
            frameBytesP50: Self.percentile(frameBytes, percentile: 0.50),
            frameBytesP95: Self.percentile(frameBytes, percentile: 0.95),
            frameBytesP99: Self.percentile(frameBytes, percentile: 0.99),
            keyframeBytesP50: Self.percentile(keyframeBytes, percentile: 0.50),
            keyframeBytesP95: Self.percentile(keyframeBytes, percentile: 0.95),
            keyframeBytesP99: Self.percentile(keyframeBytes, percentile: 0.99),
            rateControlStrategy: strategy,
            rateLimitBytes: limitBytes,
            rateLimitWindowMs: limitWindowSeconds.map { Int(($0 * 1000.0).rounded()) }
        )
    }

    private func trimSamples(olderThan cutoff: CFAbsoluteTime) {
        guard let firstIndexToKeep = samples.firstIndex(where: { $0.timestamp >= cutoff }) else {
            samples.removeAll(keepingCapacity: true)
            return
        }
        if firstIndexToKeep > 0 {
            samples.removeFirst(firstIndexToKeep)
        }
    }

    private static func percentile(_ values: [Int], percentile: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let clamped = max(0, min(1, percentile))
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.up))
        return sorted[min(sorted.count - 1, index)]
    }
}

#endif
