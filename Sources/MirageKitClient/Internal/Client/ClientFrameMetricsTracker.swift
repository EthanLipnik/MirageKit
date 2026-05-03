//
//  ClientFrameMetricsTracker.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/25/26.
//
//  Lock-based frame metrics sampling for client streams.
//

import Foundation
import MirageKit

final class ClientFrameMetricsTracker: @unchecked Sendable {
    struct DecodedFrameRecord: Sendable, Equatable {
        let isFirstFrame: Bool
        let gapMs: Double
    }

    struct ReceivedFrameRecord: Sendable, Equatable {
        let gapMs: Double
    }

    struct Snapshot: Sendable, Equatable {
        let decodedFPS: Double
        let receivedFPS: Double
        let queueDroppedFrames: UInt64
        let receivedWorstGapMs: Double
        let receivedFrameIntervalP95Ms: Double
        let receivedFrameIntervalP99Ms: Double
    }

    private let lock = NSLock()
    private var decodedSampler = FrameRateSampler()
    private var receivedSampler = FrameRateSampler()
    private var decodedCadenceSampler = FrameIntervalSampler()
    private var receivedCadenceSampler = FrameIntervalSampler()
    private var queueDroppedFrames: UInt64 = 0
    private var sentFirstFrame = false

    func recordDecodedFrame(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> DecodedFrameRecord {
        lock.lock()
        decodedSampler.record(now: now)
        let gapMs = decodedCadenceSampler.record(now: now)
        let isFirstFrame = !sentFirstFrame
        if isFirstFrame { sentFirstFrame = true }
        lock.unlock()
        return DecodedFrameRecord(isFirstFrame: isFirstFrame, gapMs: gapMs)
    }

    func recordReceivedFrame(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> ReceivedFrameRecord {
        lock.lock()
        receivedSampler.record(now: now)
        let gapMs = receivedCadenceSampler.record(now: now)
        lock.unlock()
        return ReceivedFrameRecord(gapMs: gapMs)
    }

    func recordQueueDrop(count: UInt64 = 1) {
        lock.lock()
        queueDroppedFrames &+= count
        lock.unlock()
    }

    func snapshot(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Snapshot {
        lock.lock()
        let decodedFPS = decodedSampler.snapshot(now: now)
        let receivedFPS = receivedSampler.snapshot(now: now)
        let receivedCadence = receivedCadenceSampler.snapshot(now: now)
        let dropped = queueDroppedFrames
        lock.unlock()
        return Snapshot(
            decodedFPS: decodedFPS,
            receivedFPS: receivedFPS,
            queueDroppedFrames: dropped,
            receivedWorstGapMs: receivedCadence.worstGapMs,
            receivedFrameIntervalP95Ms: receivedCadence.p95Ms,
            receivedFrameIntervalP99Ms: receivedCadence.p99Ms
        )
    }

    func reset() {
        lock.lock()
        decodedSampler.reset()
        receivedSampler.reset()
        decodedCadenceSampler.reset()
        receivedCadenceSampler.reset()
        queueDroppedFrames = 0
        sentFirstFrame = false
        lock.unlock()
    }
}

private struct FrameIntervalSampler {
    private struct IntervalSample {
        let timestamp: CFAbsoluteTime
        let intervalMs: Double
    }

    struct Snapshot: Sendable, Equatable {
        let worstGapMs: Double
        let p95Ms: Double
        let p99Ms: Double
    }

    private var lastSampleTime: CFAbsoluteTime = 0
    private var samples: [IntervalSample] = []
    private var startIndex: Int = 0
    private let windowSeconds: CFAbsoluteTime = 2.0

    mutating func record(now: CFAbsoluteTime) -> Double {
        trim(now: now)
        guard lastSampleTime > 0 else {
            lastSampleTime = now
            return 0
        }
        let intervalMs = max(0, (now - lastSampleTime) * 1000)
        lastSampleTime = now
        samples.append(IntervalSample(timestamp: now, intervalMs: intervalMs))
        return intervalMs
    }

    mutating func snapshot(now: CFAbsoluteTime) -> Snapshot {
        trim(now: now)
        guard startIndex < samples.count else {
            return Snapshot(worstGapMs: 0, p95Ms: 0, p99Ms: 0)
        }
        let activeIntervals = samples[startIndex ..< samples.count].map(\.intervalMs)
        guard !activeIntervals.isEmpty else {
            return Snapshot(worstGapMs: 0, p95Ms: 0, p99Ms: 0)
        }

        let sorted = activeIntervals.sorted()
        return Snapshot(
            worstGapMs: activeIntervals.max() ?? 0,
            p95Ms: percentile(sorted: sorted, percentile: 0.95),
            p99Ms: percentile(sorted: sorted, percentile: 0.99)
        )
    }

    mutating func reset() {
        lastSampleTime = 0
        samples.removeAll(keepingCapacity: false)
        startIndex = 0
    }

    private mutating func trim(now: CFAbsoluteTime) {
        guard lastSampleTime > 0 else { return }
        let cutoff = now - windowSeconds
        while startIndex < samples.count, samples[startIndex].timestamp < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }

    private func percentile(sorted: [Double], percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = max(0, min(1, percentile))
        let index = Int(ceil(clamped * Double(sorted.count))) - 1
        return sorted[max(0, min(sorted.count - 1, index))]
    }
}

private struct FrameRateSampler {
    private var samples: [CFAbsoluteTime] = []
    private var startIndex: Int = 0
    private let windowSeconds: CFAbsoluteTime = 1.0

    @discardableResult
    mutating func record(now: CFAbsoluteTime) -> Double {
        samples.append(now)
        trim(now: now)
        return Double(samples.count - startIndex)
    }

    mutating func snapshot(now: CFAbsoluteTime) -> Double {
        trim(now: now)
        return Double(samples.count - startIndex)
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: false)
        startIndex = 0
    }

    private mutating func trim(now: CFAbsoluteTime) {
        let cutoff = now - windowSeconds
        while startIndex < samples.count, samples[startIndex] < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }
}
