//
//  CaptureCadenceMetricsTracker.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import Foundation

#if os(macOS)
struct CaptureFrameStatusCounts: Sendable, Equatable {
    var complete: UInt64 = 0
    var idle: UInt64 = 0
    var blank: UInt64 = 0
    var suspended: UInt64 = 0
    var started: UInt64 = 0
    var stopped: UInt64 = 0
    var unknown: UInt64 = 0

    var total: UInt64 {
        complete + idle + blank + suspended + started + stopped + unknown
    }

    mutating func reset() {
        complete = 0
        idle = 0
        blank = 0
        suspended = 0
        started = 0
        stopped = 0
        unknown = 0
    }
}

struct CaptureCadenceMetricsSnapshot: Sendable, Equatable {
    let wallClockGapWorstMs: Double
    let wallClockGapP95Ms: Double
    let wallClockGapP99Ms: Double
    let presentationGapWorstMs: Double
    let presentationGapP95Ms: Double
    let presentationGapP99Ms: Double
    let displayTimeGapWorstMs: Double
    let displayTimeGapP95Ms: Double
    let displayTimeGapP99Ms: Double
    let deliveredFrameGapWorstMs: Double
    let deliveredFrameGapP95Ms: Double
    let deliveredFrameGapP99Ms: Double
    let callbackDurationAverageMs: Double
    let callbackDurationMaxMs: Double
    let callbackDurationP95Ms: Double
    let callbackDurationP99Ms: Double
    let longFrameGapCount: UInt64
    let displayTimeDriftCount: UInt64
    let statusCounts: CaptureFrameStatusCounts
    let cadenceDropCount: UInt64
    let admissionDropCount: UInt64
    let sampleOverwriteCount: UInt64

    var virtualDisplayTimingSuspect: Bool {
        displayTimeDriftCount > 0 ||
            displayTimeGapP99Ms >= 35.0 ||
            deliveredFrameGapP99Ms >= 35.0 ||
            wallClockGapP99Ms >= 35.0
    }
}

struct CaptureCadenceMetricsTracker: Sendable, Equatable {
    private var expectedFrameRate: Double
    private var targetFrameRate: Double
    private var lastWallClockFrameTime: Double?
    private var lastObservedWallGapMs: Double?
    private var lastPresentationTime: Double?
    private var lastDisplayTime: Double?
    private var lastDeliveredFrameTime: Double?
    private var wallClockGaps = CaptureDoubleSampleWindow(capacity: 512)
    private var presentationGaps = CaptureDoubleSampleWindow(capacity: 512)
    private var displayTimeGaps = CaptureDoubleSampleWindow(capacity: 512)
    private var deliveredFrameGaps = CaptureDoubleSampleWindow(capacity: 512)
    private var callbackDurations = CaptureDoubleSampleWindow(capacity: 512)
    private var callbackDurationTotalMs: Double = 0
    private var callbackDurationCount: UInt64 = 0
    private var longFrameGapCount: UInt64 = 0
    private var displayTimeDriftCount: UInt64 = 0
    private var statusCounts = CaptureFrameStatusCounts()
    private var cadenceDropCount: UInt64 = 0
    private var admissionDropCount: UInt64 = 0

    init(expectedFrameRate: Double = 0, targetFrameRate: Double = 0) {
        self.expectedFrameRate = max(0, expectedFrameRate)
        self.targetFrameRate = max(0, targetFrameRate)
    }

    mutating func updateFrameRates(expectedFrameRate: Double, targetFrameRate: Double) {
        self.expectedFrameRate = max(0, expectedFrameRate)
        self.targetFrameRate = max(0, targetFrameRate)
    }

    mutating func recordScreenCallback(at wallTime: Double) {
        guard wallTime.isFinite, wallTime >= 0 else { return }
        if let lastWallClockFrameTime {
            let gapMs = max(0, (wallTime - lastWallClockFrameTime) * 1000)
            lastObservedWallGapMs = gapMs
            wallClockGaps.record(gapMs)
            if gapMs >= longGapThresholdMs {
                longFrameGapCount &+= 1
            }
        } else {
            lastObservedWallGapMs = nil
        }
        lastWallClockFrameTime = wallTime
    }

    mutating func recordFrameTiming(
        presentationTime: Double?,
        displayTime: Double?,
        wallTime: Double
    ) {
        if let presentationTime,
           presentationTime.isFinite,
           presentationTime >= 0 {
            if let lastPresentationTime {
                presentationGaps.record(max(0, (presentationTime - lastPresentationTime) * 1000))
            }
            lastPresentationTime = presentationTime
        }

        if let displayTime,
           displayTime.isFinite,
           displayTime >= 0 {
            if let lastDisplayTime {
                let displayGapMs = max(0, (displayTime - lastDisplayTime) * 1000)
                displayTimeGaps.record(displayGapMs)
                if let wallGapMs = lastObservedWallGapMs {
                    let driftThresholdMs = max(20.0, expectedFrameIntervalMs * 1.5)
                    if abs(displayGapMs - wallGapMs) >= driftThresholdMs {
                        displayTimeDriftCount &+= 1
                    }
                }
            }
            lastDisplayTime = displayTime
        }
    }

    mutating func recordDeliveredFrame(at wallTime: Double) {
        guard wallTime.isFinite, wallTime >= 0 else { return }
        if let lastDeliveredFrameTime {
            deliveredFrameGaps.record(max(0, (wallTime - lastDeliveredFrameTime) * 1000))
        }
        lastDeliveredFrameTime = wallTime
    }

    mutating func recordCallbackDuration(_ durationMs: Double) {
        guard durationMs.isFinite, durationMs >= 0 else { return }
        callbackDurations.record(durationMs)
        callbackDurationTotalMs += durationMs
        callbackDurationCount &+= 1
    }

    mutating func recordStatus(_ status: CaptureFrameStatusBucket) {
        switch status {
        case .complete:
            statusCounts.complete &+= 1
        case .idle:
            statusCounts.idle &+= 1
        case .blank:
            statusCounts.blank &+= 1
        case .suspended:
            statusCounts.suspended &+= 1
        case .started:
            statusCounts.started &+= 1
        case .stopped:
            statusCounts.stopped &+= 1
        case .unknown:
            statusCounts.unknown &+= 1
        }
    }

    mutating func recordCadenceDrop() {
        cadenceDropCount &+= 1
    }

    mutating func recordAdmissionDrop() {
        admissionDropCount &+= 1
    }

    mutating func consumeSnapshot() -> CaptureCadenceMetricsSnapshot {
        let snapshot = makeSnapshot()
        resetWindow()
        return snapshot
    }

    func snapshot() -> CaptureCadenceMetricsSnapshot {
        makeSnapshot()
    }

    private var expectedFrameIntervalMs: Double {
        let rate = targetFrameRate > 0 ? targetFrameRate : expectedFrameRate
        guard rate > 0 else { return 16.667 }
        return 1000.0 / rate
    }

    private var longGapThresholdMs: Double {
        max(50.0, expectedFrameIntervalMs * 2.0)
    }

    private func makeSnapshot() -> CaptureCadenceMetricsSnapshot {
        let wallStats = wallClockGaps.statistics()
        let presentationStats = presentationGaps.statistics()
        let displayStats = displayTimeGaps.statistics()
        let deliveredStats = deliveredFrameGaps.statistics()
        let callbackStats = callbackDurations.statistics()
        let callbackAverage = callbackDurationCount > 0
            ? callbackDurationTotalMs / Double(callbackDurationCount)
            : 0
        return CaptureCadenceMetricsSnapshot(
            wallClockGapWorstMs: wallStats.worst,
            wallClockGapP95Ms: wallStats.p95,
            wallClockGapP99Ms: wallStats.p99,
            presentationGapWorstMs: presentationStats.worst,
            presentationGapP95Ms: presentationStats.p95,
            presentationGapP99Ms: presentationStats.p99,
            displayTimeGapWorstMs: displayStats.worst,
            displayTimeGapP95Ms: displayStats.p95,
            displayTimeGapP99Ms: displayStats.p99,
            deliveredFrameGapWorstMs: deliveredStats.worst,
            deliveredFrameGapP95Ms: deliveredStats.p95,
            deliveredFrameGapP99Ms: deliveredStats.p99,
            callbackDurationAverageMs: callbackAverage,
            callbackDurationMaxMs: callbackStats.worst,
            callbackDurationP95Ms: callbackStats.p95,
            callbackDurationP99Ms: callbackStats.p99,
            longFrameGapCount: longFrameGapCount,
            displayTimeDriftCount: displayTimeDriftCount,
            statusCounts: statusCounts,
            cadenceDropCount: cadenceDropCount,
            admissionDropCount: admissionDropCount,
            sampleOverwriteCount: wallStats.overwriteCount +
                presentationStats.overwriteCount +
                displayStats.overwriteCount +
                deliveredStats.overwriteCount +
                callbackStats.overwriteCount
        )
    }

    private mutating func resetWindow() {
        wallClockGaps.reset()
        presentationGaps.reset()
        displayTimeGaps.reset()
        deliveredFrameGaps.reset()
        callbackDurations.reset()
        callbackDurationTotalMs = 0
        callbackDurationCount = 0
        longFrameGapCount = 0
        displayTimeDriftCount = 0
        statusCounts.reset()
        cadenceDropCount = 0
        admissionDropCount = 0
    }
}

enum CaptureFrameStatusBucket: Sendable, Equatable {
    case complete
    case idle
    case blank
    case suspended
    case started
    case stopped
    case unknown
}

private struct CaptureDoubleSampleWindow: Sendable, Equatable {
    private var values: [Double]
    private var nextIndex = 0
    private var count = 0
    private var overwriteCount: UInt64 = 0

    init(capacity: Int) {
        values = Array(repeating: 0, count: max(1, capacity))
    }

    mutating func record(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        if count == values.count {
            overwriteCount &+= 1
        } else {
            count += 1
        }
        values[nextIndex] = value
        nextIndex = (nextIndex + 1) % values.count
    }

    func statistics() -> CaptureDoubleSampleStatistics {
        guard count > 0 else { return CaptureDoubleSampleStatistics(overwriteCount: overwriteCount) }
        var samples = Array(values.prefix(count))
        samples.sort()
        return CaptureDoubleSampleStatistics(
            worst: samples.last ?? 0,
            p95: Self.percentile(0.95, samples: samples),
            p99: Self.percentile(0.99, samples: samples),
            overwriteCount: overwriteCount
        )
    }

    mutating func reset() {
        nextIndex = 0
        count = 0
        overwriteCount = 0
    }

    private static func percentile(_ percentile: Double, samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let clamped = max(0, min(1, percentile))
        let index = max(0, min(samples.count - 1, Int(ceil(clamped * Double(samples.count))) - 1))
        return samples[index]
    }
}

private struct CaptureDoubleSampleStatistics: Sendable, Equatable {
    var worst: Double = 0
    var p95: Double = 0
    var p99: Double = 0
    var overwriteCount: UInt64 = 0
}
#endif
