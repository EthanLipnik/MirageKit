//
//  CaptureCadenceMetricsTracker.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import Foundation

#if os(macOS)
struct CaptureCadenceMetricsSnapshot: Equatable {
    let wallClockGapWorstMs: Double
    let wallClockGapP95Ms: Double
    let wallClockGapP99Ms: Double
    let displayTimeGapWorstMs: Double
    let displayTimeGapP95Ms: Double
    let displayTimeGapP99Ms: Double
    let deliveredFrameGapWorstMs: Double
    let deliveredFrameGapP95Ms: Double
    let deliveredFrameGapP99Ms: Double
    let callbackDurationP95Ms: Double
    let callbackDurationP99Ms: Double
    let longFrameGapCount: UInt64
    let displayTimeDriftCount: UInt64
    let blankFrameStatusCount: UInt64
    let suspendedFrameStatusCount: UInt64
    let stoppedFrameStatusCount: UInt64
    let cadenceDropCount: UInt64

    var virtualDisplayTimingSuspect: Bool {
        displayTimeDriftCount > 0 ||
            displayTimeGapP99Ms >= 35.0 ||
            deliveredFrameGapP99Ms >= 35.0 ||
            wallClockGapP99Ms >= 35.0
    }
}

struct CaptureCadenceMetricsTracker: Equatable {
    private var expectedFrameRate: Double
    private var targetFrameRate: Double
    private var lastWallClockFrameTime: Double?
    private var lastObservedWallGapMs: Double?
    private var lastDisplayTime: Double?
    private var lastDeliveredFrameTime: Double?
    private var wallClockGaps = CaptureDoubleSampleWindow(capacity: 512)
    private var displayTimeGaps = CaptureDoubleSampleWindow(capacity: 512)
    private var deliveredFrameGaps = CaptureDoubleSampleWindow(capacity: 512)
    private var callbackDurations = CaptureDoubleSampleWindow(capacity: 512)
    private var longFrameGapCount: UInt64 = 0
    private var displayTimeDriftCount: UInt64 = 0
    private var blankFrameStatusCount: UInt64 = 0
    private var suspendedFrameStatusCount: UInt64 = 0
    private var stoppedFrameStatusCount: UInt64 = 0
    private var cadenceDropCount: UInt64 = 0

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
            if gapMs >= max(50.0, expectedFrameIntervalMs * 2.0) {
                longFrameGapCount &+= 1
            }
        } else {
            lastObservedWallGapMs = nil
        }
        lastWallClockFrameTime = wallTime
    }

    mutating func recordFrameTiming(displayTime: Double?) {
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
    }

    mutating func recordLimitedStatus(_ status: CaptureLimitedFrameStatus) {
        switch status {
        case .blank:
            blankFrameStatusCount &+= 1
        case .suspended:
            suspendedFrameStatusCount &+= 1
        case .stopped:
            stoppedFrameStatusCount &+= 1
        }
    }

    mutating func recordCadenceDrop() {
        cadenceDropCount &+= 1
    }

    mutating func consumeSnapshot() -> CaptureCadenceMetricsSnapshot {
        let currentSnapshot = snapshot
        resetWindow()
        return currentSnapshot
    }

    /// Aggregated capture cadence metrics for the current sampling window.
    var snapshot: CaptureCadenceMetricsSnapshot {
        let wallStats = wallClockGaps.statistics
        let displayStats = displayTimeGaps.statistics
        let deliveredStats = deliveredFrameGaps.statistics
        let callbackStats = callbackDurations.statistics
        return CaptureCadenceMetricsSnapshot(
            wallClockGapWorstMs: wallStats.worst,
            wallClockGapP95Ms: wallStats.p95,
            wallClockGapP99Ms: wallStats.p99,
            displayTimeGapWorstMs: displayStats.worst,
            displayTimeGapP95Ms: displayStats.p95,
            displayTimeGapP99Ms: displayStats.p99,
            deliveredFrameGapWorstMs: deliveredStats.worst,
            deliveredFrameGapP95Ms: deliveredStats.p95,
            deliveredFrameGapP99Ms: deliveredStats.p99,
            callbackDurationP95Ms: callbackStats.p95,
            callbackDurationP99Ms: callbackStats.p99,
            longFrameGapCount: longFrameGapCount,
            displayTimeDriftCount: displayTimeDriftCount,
            blankFrameStatusCount: blankFrameStatusCount,
            suspendedFrameStatusCount: suspendedFrameStatusCount,
            stoppedFrameStatusCount: stoppedFrameStatusCount,
            cadenceDropCount: cadenceDropCount
        )
    }

    private var expectedFrameIntervalMs: Double {
        let rate = targetFrameRate > 0 ? targetFrameRate : expectedFrameRate
        guard rate > 0 else { return 16.667 }
        return 1000.0 / rate
    }

    private mutating func resetWindow() {
        wallClockGaps.reset()
        displayTimeGaps.reset()
        deliveredFrameGaps.reset()
        callbackDurations.reset()
        longFrameGapCount = 0
        displayTimeDriftCount = 0
        blankFrameStatusCount = 0
        suspendedFrameStatusCount = 0
        stoppedFrameStatusCount = 0
        cadenceDropCount = 0
    }
}

enum CaptureLimitedFrameStatus: Equatable {
    case blank
    case suspended
    case stopped
}

private struct CaptureDoubleSampleWindow: Equatable {
    private var values: [Double]
    private var nextIndex = 0
    private var sampleCount = 0

    init(capacity: Int) {
        values = Array(repeating: 0, count: max(1, capacity))
    }

    mutating func record(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        if sampleCount < values.count {
            sampleCount += 1
        }
        values[nextIndex] = value
        nextIndex = (nextIndex + 1) % values.count
    }

    var statistics: CaptureDoubleSampleStatistics {
        guard sampleCount > 0 else { return CaptureDoubleSampleStatistics() }
        var samples = Array(values.prefix(sampleCount))
        samples.sort()
        return CaptureDoubleSampleStatistics(
            worst: samples.last ?? 0,
            p95: Self.percentile(0.95, samples: samples),
            p99: Self.percentile(0.99, samples: samples)
        )
    }

    mutating func reset() {
        nextIndex = 0
        sampleCount = 0
    }

    private static func percentile(_ percentile: Double, samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let clamped = max(0, min(1, percentile))
        let index = max(0, min(samples.count - 1, Int(ceil(clamped * Double(samples.count))) - 1))
        return samples[index]
    }
}

private struct CaptureDoubleSampleStatistics: Equatable {
    var worst: Double = 0
    var p95: Double = 0
    var p99: Double = 0
}
#endif
