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
    @Test("Display capture policy defers restart beyond soft stall threshold")
    func displayPolicyDefersRestart() {
        let policy = WindowCaptureEngine.resolveStallPolicy(
            windowID: 0,
            frameRate: 60,
            configuredSoftStallLimit: 2.0
        )

        #expect(policy.softStallThreshold == 2.0)
        #expect(policy.hardRestartThreshold > policy.softStallThreshold)
        #expect(policy.restartDebounce > 0)
        #expect(policy.cancellationGrace > 0)
    }

    @Test("Window capture policy keeps hard threshold equal to soft threshold")
    func windowPolicyMaintainsImmediateRestartThreshold() {
        let policy = WindowCaptureEngine.resolveStallPolicy(
            windowID: 42,
            frameRate: 60,
            configuredSoftStallLimit: 1.0
        )

        #expect(policy.softStallThreshold == 8.0)
        #expect(policy.hardRestartThreshold == policy.softStallThreshold)
    }
}
#endif
