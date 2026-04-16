//
//  CapturePressurePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//
//  Coverage for capture-pressure tuning and stall-policy thresholds.
//

import CoreMedia
@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Capture Queue Policy")
struct CapturePressureProfileTests {
    @Test("Resolved SCK queue depth stays within supported bounds at high-res 60 Hz")
    func sckQueueDepth60Hz() {
        let baseline = WindowCaptureEngine.resolveSCKQueueDepth(
            width: 6_016,
            height: 3_384,
            frameRate: 60,
            latencyMode: .lowestLatency,
            overrideDepth: nil
        )
        let tuned = WindowCaptureEngine.resolveSCKQueueDepth(
            width: 6_016,
            height: 3_384,
            frameRate: 60,
            latencyMode: .lowestLatency,
            overrideDepth: nil
        )

        #expect((3 ... 8).contains(baseline))
        #expect((3 ... 8).contains(tuned))
        #expect(baseline == 8)
        #expect(tuned == baseline)
    }

    @Test("Resolved SCK queue depth uses full SCK headroom at 120 Hz")
    func sckQueueDepth120Hz() {
        let baseline = WindowCaptureEngine.resolveSCKQueueDepth(
            width: 6_016,
            height: 3_384,
            frameRate: 120,
            latencyMode: .lowestLatency,
            overrideDepth: nil
        )
        let tuned = WindowCaptureEngine.resolveSCKQueueDepth(
            width: 6_016,
            height: 3_384,
            frameRate: 120,
            latencyMode: .lowestLatency,
            overrideDepth: nil
        )

        #expect((3 ... 8).contains(baseline))
        #expect((3 ... 8).contains(tuned))
        #expect(baseline == 8)
        #expect(tuned == baseline)
    }
}

@Suite("Capture Rate Policy")
struct CaptureRatePolicyTests {
    @Test("Display refresh cadence caps effective capture rate when enabled")
    func displayRefreshCadenceCapsEffectiveRate() {
        #expect(
            WindowCaptureEngine.resolvedEffectiveCaptureRate(
                requestedFrameRate: 120,
                displayRefreshRate: 60,
                usesDisplayRefreshCadence: true
            ) == 60
        )
        #expect(
            WindowCaptureEngine.resolvedEffectiveCaptureRate(
                requestedFrameRate: 120,
                displayRefreshRate: 144,
                usesDisplayRefreshCadence: true
            ) == 120
        )
        #expect(
            WindowCaptureEngine.resolvedEffectiveCaptureRate(
                requestedFrameRate: 120,
                displayRefreshRate: 60,
                usesDisplayRefreshCadence: false
            ) == 120
        )
    }

    @Test("Native display cadence uses zero minimum frame interval")
    func nativeDisplayCadenceUsesZeroMinimumFrameInterval() {
        #expect(
            WindowCaptureEngine.resolvedMinimumFrameInterval(
                requestedFrameRate: 120,
                displayRefreshRate: 120,
                usesDisplayRefreshCadence: true
            ) == .zero
        )
        #expect(
            WindowCaptureEngine.resolvedMinimumFrameInterval(
                requestedFrameRate: 120,
                displayRefreshRate: 60,
                usesDisplayRefreshCadence: true
            ) == .zero
        )
        #expect(
            WindowCaptureEngine.resolvedMinimumFrameInterval(
                requestedFrameRate: 60,
                displayRefreshRate: 120,
                usesDisplayRefreshCadence: true
            ) != .zero
        )
        #expect(
            WindowCaptureEngine.resolvedMinimumFrameInterval(
                requestedFrameRate: 120,
                displayRefreshRate: 120,
                usesDisplayRefreshCadence: false
            ) != .zero
        )
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
        var originPresentationTime: Double?
        var lastAdmittedSlotIndex: Int64 = -1
        var dropped = 0
        var admitted = 0

        for index in 0 ..< 120 {
            let timestamp = Double(index) * cadence120
            let decision = CaptureStreamOutput.cadenceDecision(
                originPresentationTime: originPresentationTime,
                lastAdmittedSlotIndex: lastAdmittedSlotIndex,
                presentationTime: timestamp,
                targetFrameRate: targetFPS,
                isIdleFrame: false
            )
            originPresentationTime = decision.originPresentationTime
            lastAdmittedSlotIndex = decision.admittedSlotIndex
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

        var originPresentationTime: Double?
        var lastAdmittedSlotIndex: Int64 = -1
        var dropped = 0
        var admitted = 0

        for index in 0 ..< 120 {
            let jitter = jitters[index % jitters.count]
            let timestamp = (Double(index) * cadence60) + jitter
            let decision = CaptureStreamOutput.cadenceDecision(
                originPresentationTime: originPresentationTime,
                lastAdmittedSlotIndex: lastAdmittedSlotIndex,
                presentationTime: timestamp,
                targetFrameRate: targetFPS,
                isIdleFrame: false
            )
            originPresentationTime = decision.originPresentationTime
            lastAdmittedSlotIndex = decision.admittedSlotIndex
            if decision.shouldDrop {
                dropped += 1
            } else {
                admitted += 1
            }
        }

        #expect(admitted >= 116)
        #expect(dropped <= 4)
    }

    @Test("120 Hz target stays near line rate under mild oversupply jitter")
    func mildOversupplyNear120RemainsNearLineRate() {
        let targetFPS = 120.0
        let oversuppliedCadence = 1.0 / 130.0
        let jitters: [Double] = [0.0003, -0.0002, 0.0004, -0.0001]

        var originPresentationTime: Double?
        var lastAdmittedSlotIndex: Int64 = -1
        var dropped = 0
        var admitted = 0

        for index in 0 ..< 650 {
            let jitter = jitters[index % jitters.count]
            let timestamp = (Double(index) * oversuppliedCadence) + jitter
            let decision = CaptureStreamOutput.cadenceDecision(
                originPresentationTime: originPresentationTime,
                lastAdmittedSlotIndex: lastAdmittedSlotIndex,
                presentationTime: timestamp,
                targetFrameRate: targetFPS,
                isIdleFrame: false
            )
            originPresentationTime = decision.originPresentationTime
            lastAdmittedSlotIndex = decision.admittedSlotIndex
            if decision.shouldDrop {
                dropped += 1
            } else {
                admitted += 1
            }
        }

        #expect(admitted >= 595)
        #expect(dropped <= 55)
    }

    @Test("Idle frames bypass cadence gate for continuity")
    func idleFramesBypassCadenceGate() {
        let decision = CaptureStreamOutput.cadenceDecision(
            originPresentationTime: 10.0,
            lastAdmittedSlotIndex: 5,
            presentationTime: 10.001,
            targetFrameRate: 60.0,
            isIdleFrame: true
        )
        #expect(decision.shouldDrop == false)
        #expect(decision.originPresentationTime == 10.0)
        #expect(decision.admittedSlotIndex == 5)
    }
}
#endif
