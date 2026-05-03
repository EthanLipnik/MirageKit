//
//  CaptureCadenceMetricsTrackerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Capture Cadence Metrics Tracker")
struct CaptureCadenceMetricsTrackerTests {
    @Test("Cadence windows track worst and percentile gaps")
    func cadenceWindowTracksWorstAndPercentiles() {
        var tracker = CaptureCadenceMetricsTracker(expectedFrameRate: 60, targetFrameRate: 60)
        let times = [10.000, 10.016, 10.032, 10.082, 10.182]

        for time in times {
            tracker.recordScreenCallback(at: time)
            tracker.recordFrameTiming(
                presentationTime: time,
                displayTime: time,
                wallTime: time
            )
            tracker.recordDeliveredFrame(at: time)
            tracker.recordCallbackDuration((time - 9.9) * 0.1)
        }

        let snapshot = tracker.snapshot()
        #expect(snapshot.wallClockGapWorstMs > 99.9)
        #expect(snapshot.wallClockGapP95Ms > 99.9)
        #expect(snapshot.displayTimeGapP99Ms > 99.9)
        #expect(snapshot.deliveredFrameGapWorstMs > 99.9)
        #expect(snapshot.longFrameGapCount == 2)
        #expect(snapshot.callbackDurationP99Ms > 0)
    }

    @Test("Status, drop, and reset counters are windowed")
    func statusDropAndResetCountersAreWindowed() {
        var tracker = CaptureCadenceMetricsTracker(expectedFrameRate: 60, targetFrameRate: 60)

        tracker.recordStatus(.complete)
        tracker.recordStatus(.blank)
        tracker.recordStatus(.suspended)
        tracker.recordCadenceDrop()
        tracker.recordAdmissionDrop()

        let first = tracker.consumeSnapshot()
        #expect(first.statusCounts.complete == 1)
        #expect(first.statusCounts.blank == 1)
        #expect(first.statusCounts.suspended == 1)
        #expect(first.cadenceDropCount == 1)
        #expect(first.admissionDropCount == 1)

        let second = tracker.snapshot()
        #expect(second.statusCounts.total == 0)
        #expect(second.cadenceDropCount == 0)
        #expect(second.admissionDropCount == 0)
    }

    @Test("Ring buffer overwrite accounting is exposed")
    func ringBufferOverwriteAccountingIsExposed() {
        var tracker = CaptureCadenceMetricsTracker(expectedFrameRate: 60, targetFrameRate: 60)

        for index in 0 ..< 700 {
            tracker.recordScreenCallback(at: 20 + Double(index) * 0.016)
        }

        let snapshot = tracker.snapshot()
        #expect(snapshot.sampleOverwriteCount > 0)
    }
}
#endif
