//
//  HostHighRefreshFrameAdmissionStateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/19/26.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Host High Refresh Frame Admission State")
struct HostHighRefreshFrameAdmissionStateTests {
    @Test("On-time high refresh frames remain admitted above sixty FPS")
    func onTimeHighRefreshFramesRemainAdmittedAboveSixtyFPS() {
        var state = HostHighRefreshFrameAdmissionState()

        let first = state.evaluateAdmission(
            currentFrameRate: 120,
            frameCaptureTime: 10.000,
            reason: "encoder-over-floor-budget",
            now: 10.006
        )
        let second = state.evaluateAdmission(
            currentFrameRate: 120,
            frameCaptureTime: 10.008,
            reason: "encoder-over-floor-budget",
            now: 10.014
        )

        #expect(!first)
        #expect(!second)
        #expect(state.mode == .inactive)
        #expect(state.totalSkipCount == 0)
        #expect(state.lastAdmittedFrameTime == 10.014)
    }

    @Test("Stale catch-up frame is skipped inside protected sixty FPS interval")
    func staleCatchUpFrameIsSkippedInsideProtectedSixtyFPSInterval() {
        var state = HostHighRefreshFrameAdmissionState()

        let first = state.evaluateAdmission(
            currentFrameRate: 120,
            frameCaptureTime: 10.000,
            reason: "stale-frame",
            now: 10.000
        )
        let second = state.evaluateAdmission(
            currentFrameRate: 120,
            frameCaptureTime: 9.990,
            reason: "stale-frame",
            now: 10.010
        )

        #expect(!first)
        #expect(second)
        #expect(state.mode == .protecting)
        #expect(state.reason == "stale-frame")
        #expect(state.totalSkipCount == 1)
        #expect(state.lastAdmittedFrameTime == 10.000)
    }

    @Test("Ninety FPS stream protects the sixty FPS stale interval")
    func ninetyFPSStreamProtectsTheSixtyFPSStaleInterval() {
        var state = HostHighRefreshFrameAdmissionState()

        _ = state.evaluateAdmission(
            currentFrameRate: 90,
            frameCaptureTime: 10.000,
            reason: "stale-frame",
            now: 10.000
        )
        let skipped = state.evaluateAdmission(
            currentFrameRate: 90,
            frameCaptureTime: 9.982,
            reason: "stale-frame",
            now: 10.010
        )

        #expect(skipped)
        #expect(state.mode == .protecting)
        #expect(state.totalSkipCount == 1)
    }

    @Test("Protected floor admits stale frame once sixty FPS interval has elapsed")
    func protectedFloorAdmitsStaleFrameOnceSixtyFPSIntervalHasElapsed() {
        var state = HostHighRefreshFrameAdmissionState()

        _ = state.evaluateAdmission(
            currentFrameRate: 120,
            frameCaptureTime: 10.000,
            reason: "stale-frame",
            now: 10.000
        )
        let admitted = state.evaluateAdmission(
            currentFrameRate: 120,
            frameCaptureTime: 9.995,
            reason: "stale-frame",
            now: 10.020
        )

        #expect(!admitted)
        #expect(state.mode == .inactive)
        #expect(state.totalSkipCount == 0)
        #expect(state.lastAdmittedFrameTime == 10.020)
    }

    @Test("Plain reset clears protected admission window")
    func plainResetClearsProtectedAdmissionWindow() {
        var state = HostHighRefreshFrameAdmissionState()

        _ = state.evaluateAdmission(
            currentFrameRate: 120,
            frameCaptureTime: 10.000,
            reason: "stale-frame",
            now: 10.000
        )
        state.reset()
        let skipped = state.evaluateAdmission(
            currentFrameRate: 120,
            frameCaptureTime: 9.990,
            reason: "stale-frame",
            now: 10.010
        )

        #expect(!skipped)
        #expect(state.mode == .inactive)
        #expect(state.totalSkipCount == 0)
        #expect(state.lastAdmittedFrameTime == 10.010)
    }

    @Test("High refresh pacing is inactive at sixty FPS and below")
    func highRefreshPacingIsInactiveAtSixtyFPSAndBelow() {
        var state = HostHighRefreshFrameAdmissionState()

        let first = state.evaluateAdmission(
            currentFrameRate: 60,
            frameCaptureTime: 9.950,
            reason: "stale-frame",
            now: 10.000
        )
        let second = state.evaluateAdmission(
            currentFrameRate: 30,
            frameCaptureTime: 9.900,
            reason: "stale-frame",
            now: 10.010
        )

        #expect(!first)
        #expect(!second)
        #expect(state.mode == .inactive)
        #expect(state.totalSkipCount == 0)
    }
}
#endif
