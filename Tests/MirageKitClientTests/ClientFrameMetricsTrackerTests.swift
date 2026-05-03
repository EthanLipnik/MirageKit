//
//  ClientFrameMetricsTrackerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

@testable import MirageKitClient
import Foundation
import Testing

@Suite("Client Frame Metrics Tracker")
struct ClientFrameMetricsTrackerTests {
    @Test("Received-frame cadence snapshot tracks worst, P95, and P99 gaps")
    func receivedCadenceWindow() {
        let tracker = ClientFrameMetricsTracker()

        _ = tracker.recordReceivedFrame(now: 100.000)
        let firstGap = tracker.recordReceivedFrame(now: 100.016).gapMs
        let worstGap = tracker.recordReceivedFrame(now: 100.050).gapMs
        _ = tracker.recordReceivedFrame(now: 100.066)

        let snapshot = tracker.snapshot(now: 100.066)

        #expect(firstGap > 15.9)
        #expect(firstGap < 16.1)
        #expect(worstGap > 33.9)
        #expect(worstGap < 34.1)
        #expect(snapshot.receivedWorstGapMs > 33.9)
        #expect(snapshot.receivedWorstGapMs < 34.1)
        #expect(snapshot.receivedFrameIntervalP95Ms > 33.9)
        #expect(snapshot.receivedFrameIntervalP99Ms > 33.9)
    }

    @Test("Reset clears received cadence windows")
    func resetClearsReceivedCadence() {
        let tracker = ClientFrameMetricsTracker()

        _ = tracker.recordReceivedFrame(now: 200.000)
        _ = tracker.recordReceivedFrame(now: 200.050)
        tracker.reset()

        let snapshot = tracker.snapshot(now: 200.100)
        #expect(snapshot.receivedWorstGapMs == 0)
        #expect(snapshot.receivedFrameIntervalP95Ms == 0)
        #expect(snapshot.receivedFrameIntervalP99Ms == 0)
        #expect(snapshot.receivedFPS == 0)
    }
}
