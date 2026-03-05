//
//  CapturePressurePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//
//  Coverage for capture-pressure tuning and stall-policy thresholds.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Capture Pressure Profile")
struct CapturePressureProfileTests {
    @Test("Tuned profile lowers queue depth for high-res 60 Hz lowest-latency capture")
    func tunedQueueDepth60Hz() {
        let baseline = WindowCaptureEngine.resolveCaptureQueueDepth(
            width: 6_016,
            height: 3_384,
            frameRate: 60,
            latencyMode: .lowestLatency,
            profile: .baseline,
            overrideDepth: nil
        )
        let tuned = WindowCaptureEngine.resolveCaptureQueueDepth(
            width: 6_016,
            height: 3_384,
            frameRate: 60,
            latencyMode: .lowestLatency,
            profile: .tuned,
            overrideDepth: nil
        )

        #expect(tuned < baseline)
    }

    @Test("Tuned profile lowers queue depth for high-res 120 Hz lowest-latency capture")
    func tunedQueueDepth120Hz() {
        let baseline = WindowCaptureEngine.resolveCaptureQueueDepth(
            width: 6_016,
            height: 3_384,
            frameRate: 120,
            latencyMode: .lowestLatency,
            profile: .baseline,
            overrideDepth: nil
        )
        let tuned = WindowCaptureEngine.resolveCaptureQueueDepth(
            width: 6_016,
            height: 3_384,
            frameRate: 120,
            latencyMode: .lowestLatency,
            profile: .tuned,
            overrideDepth: nil
        )

        #expect(tuned < baseline)
    }

    @Test("Tuned profile lowers copy in-flight cap under high-pressure capture pools")
    func tunedCopyInFlightLimit() {
        let baseline = CaptureStreamOutput.resolvedCopyInFlightLimit(
            expectedFrameRate: 120,
            poolMinimumBufferCount: 12,
            pressureProfile: .baseline
        )
        let tuned = CaptureStreamOutput.resolvedCopyInFlightLimit(
            expectedFrameRate: 120,
            poolMinimumBufferCount: 12,
            pressureProfile: .tuned
        )

        #expect(tuned < baseline)
    }
}

@Suite("Capture Stall Policy")
struct CaptureStallPolicyTests {
    @Test("Auto desktop display policy uses aggressive restart thresholds")
    func autoDesktopPolicyUsesAggressiveThresholds() {
        let autoPolicy = WindowCaptureEngine.resolveStallPolicy(
            windowID: 0,
            captureMode: .display,
            latencyMode: .auto,
            frameRate: 60,
            configuredSoftStallLimit: 2.0
        )
        let smoothestPolicy = WindowCaptureEngine.resolveStallPolicy(
            windowID: 0,
            captureMode: .display,
            latencyMode: .smoothest,
            frameRate: 60,
            configuredSoftStallLimit: 2.0
        )

        #expect(abs(autoPolicy.softStallThreshold - 1.0) < 0.000_1)
        #expect(abs(autoPolicy.hardRestartThreshold - 1.2) < 0.000_1)
        #expect(autoPolicy.hardRestartThreshold <= 1.25)
        #expect(autoPolicy.restartDebounce == 0.08)
        #expect(autoPolicy.cancellationGrace == 0.2)

        #expect(smoothestPolicy == autoPolicy)
    }

    @Test("Lowest-latency desktop policy is less aggressive but below legacy hard restart")
    func lowestLatencyDesktopPolicyIsLessAggressiveThanAuto() {
        let autoPolicy = WindowCaptureEngine.resolveStallPolicy(
            windowID: 0,
            captureMode: .display,
            latencyMode: .auto,
            frameRate: 60,
            configuredSoftStallLimit: 2.0
        )
        let lowestLatencyPolicy = WindowCaptureEngine.resolveStallPolicy(
            windowID: 0,
            captureMode: .display,
            latencyMode: .lowestLatency,
            frameRate: 60,
            configuredSoftStallLimit: 2.0
        )

        #expect(abs(lowestLatencyPolicy.softStallThreshold - 2.0) < 0.000_1)
        #expect(abs(lowestLatencyPolicy.hardRestartThreshold - 2.5) < 0.000_1)
        #expect(lowestLatencyPolicy.hardRestartThreshold > autoPolicy.hardRestartThreshold)
        #expect(lowestLatencyPolicy.hardRestartThreshold < 4.0)
        #expect(lowestLatencyPolicy.restartDebounce == 0.05)
        #expect(lowestLatencyPolicy.cancellationGrace == 0.2)
    }

    @Test("Window capture policy keeps hard threshold equal to soft threshold")
    func windowPolicyMaintainsImmediateRestartThreshold() {
        let policy = WindowCaptureEngine.resolveStallPolicy(
            windowID: 42,
            captureMode: .window,
            latencyMode: .auto,
            frameRate: 60,
            configuredSoftStallLimit: 1.0
        )

        #expect(policy.softStallThreshold == 8.0)
        #expect(policy.hardRestartThreshold == policy.softStallThreshold)
    }
}

@Suite("Capture Cadence Gate")
struct CaptureCadenceGateTests {
    @Test("60 Hz target drops oversupply frames from 120 Hz cadence")
    func dropsOversupplyFramesBeforeCopy() {
        let targetFPS = 60.0
        let cadence120 = 1.0 / 120.0
        var nextEmit: Double?
        var dropped = 0
        var admitted = 0

        for index in 0 ..< 120 {
            let timestamp = Double(index) * cadence120
            let decision = CaptureStreamOutput.cadenceDecision(
                nextEmitPresentationTime: nextEmit,
                presentationTime: timestamp,
                targetFrameRate: targetFPS,
                isIdleFrame: false
            )
            nextEmit = decision.nextEmitPresentationTime
            if decision.shouldDrop {
                dropped += 1
            } else {
                admitted += 1
            }
        }

        #expect(admitted >= 58)
        #expect(admitted <= 62)
        #expect(dropped >= 58)
        #expect(dropped <= 62)
    }

    @Test("Jittered 60 Hz cadence remains near 60 admitted fps")
    func jitteredCadenceRemainsStable() {
        let targetFPS = 60.0
        let cadence60 = 1.0 / 60.0
        let jitters: [Double] = [0.0004, -0.0003, 0.0002, -0.0002, 0.0003, -0.0004]

        var nextEmit: Double?
        var dropped = 0
        var admitted = 0

        for index in 0 ..< 120 {
            let jitter = jitters[index % jitters.count]
            let timestamp = (Double(index) * cadence60) + jitter
            let decision = CaptureStreamOutput.cadenceDecision(
                nextEmitPresentationTime: nextEmit,
                presentationTime: timestamp,
                targetFrameRate: targetFPS,
                isIdleFrame: false
            )
            nextEmit = decision.nextEmitPresentationTime
            if decision.shouldDrop {
                dropped += 1
            } else {
                admitted += 1
            }
        }

        #expect(admitted >= 116)
        #expect(dropped <= 4)
    }

    @Test("Idle frames bypass cadence gate for continuity")
    func idleFramesBypassCadenceGate() {
        let decision = CaptureStreamOutput.cadenceDecision(
            nextEmitPresentationTime: 10.0,
            presentationTime: 10.001,
            targetFrameRate: 60.0,
            isIdleFrame: true
        )
        #expect(decision.shouldDrop == false)
        #expect(decision.nextEmitPresentationTime == 10.0)
    }
}
#endif
