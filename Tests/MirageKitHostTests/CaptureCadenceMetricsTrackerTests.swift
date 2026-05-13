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
            tracker.recordFrameTiming(displayTime: time)
            tracker.recordDeliveredFrame(at: time)
            tracker.recordCallbackDuration((time - 9.9) * 0.1)
        }

        let snapshot = tracker.snapshot
        #expect(snapshot.wallClockGapWorstMs > 99.9)
        #expect(snapshot.wallClockGapP95Ms > 99.9)
        #expect(snapshot.displayTimeGapP99Ms > 99.9)
        #expect(snapshot.deliveredFrameGapWorstMs > 99.9)
        #expect(snapshot.longFrameGapCount == 2)
        #expect(snapshot.callbackDurationP99Ms > 0)
    }
}
#endif
