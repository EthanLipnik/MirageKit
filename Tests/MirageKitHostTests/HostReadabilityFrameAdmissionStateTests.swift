//
//  HostReadabilityFrameAdmissionStateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/19/26.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Host Readability Frame Admission State")
struct HostReadabilityFrameAdmissionStateTests {
    @Test("High refresh readability gate skips until target interval elapses")
    func highRefreshReadabilityGateSkipsUntilTargetIntervalElapses() {
        var state = HostReadabilityFrameAdmissionState()

        let first = state.evaluateAdmission(currentFrameRate: 60, reason: "encoder-lag", now: 10.000)
        let second = state.evaluateAdmission(currentFrameRate: 60, reason: "encoder-lag", now: 10.016)
        let third = state.evaluateAdmission(currentFrameRate: 60, reason: "encoder-lag", now: 10.033)
        let fourth = state.evaluateAdmission(currentFrameRate: 60, reason: "encoder-lag", now: 10.050)

        #expect(!first)
        #expect(second)
        #expect(third)
        #expect(!fourth)
        #expect(state.mode == .protecting)
        #expect(state.reason == "encoder-lag")
        #expect(state.totalSkipCount == 2)
        #expect(state.lastAdmittedFrameTime == 10.050)
    }

    @Test("Readability gate does not skip at twenty FPS or below")
    func readabilityGateDoesNotSkipAtTwentyFPSOrBelow() {
        var state = HostReadabilityFrameAdmissionState()

        let first = state.evaluateAdmission(currentFrameRate: 20, reason: "encoder-lag", now: 10.000)
        let second = state.evaluateAdmission(currentFrameRate: 20, reason: "encoder-lag", now: 10.010)
        let third = state.evaluateAdmission(currentFrameRate: 15, reason: "encoder-lag", now: 10.020)

        #expect(!first)
        #expect(!second)
        #expect(!third)
        #expect(state.mode == .inactive)
        #expect(state.totalSkipCount == 0)
    }

    @Test("Reset releases readability protection state")
    func resetReleasesReadabilityProtectionState() {
        var state = HostReadabilityFrameAdmissionState()
        _ = state.evaluateAdmission(currentFrameRate: 60, reason: "encoder-lag", now: 10.000)
        _ = state.evaluateAdmission(currentFrameRate: 60, reason: "encoder-lag", now: 10.016)

        state.reset(admittedAt: 11.000)

        #expect(state.mode == .inactive)
        #expect(state.reason == nil)
        #expect(state.skipBurstCount == 0)
        #expect(state.totalSkipCount == 1)
        #expect(state.lastAdmittedFrameTime == 11.000)
    }
}
#endif
