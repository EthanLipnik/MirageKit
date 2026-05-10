//
//  CapturePressurePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//
//  Coverage for capture-pressure tuning and stall-policy thresholds.
//

#if os(macOS)
import CoreMedia
@testable import MirageKitHost
import MirageKit
import Testing

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

    @Test("Virtual-display cadence falls back to native 60 Hz when refresh readback is missing")
    func virtualDisplayCadenceFallsBackToNative60Hz() {
        #expect(
            WindowCaptureEngine.resolvedEffectiveCaptureRate(
                requestedFrameRate: 60,
                displayRefreshRate: nil,
                usesDisplayRefreshCadence: true
            ) == 60
        )
        #expect(
            WindowCaptureEngine.resolvedMinimumFrameInterval(
                requestedFrameRate: 60,
                displayRefreshRate: nil,
                usesDisplayRefreshCadence: true
            ) == .zero
        )
        #expect(
            WindowCaptureEngine.resolvedMinimumFrameInterval(
                requestedFrameRate: 30,
                displayRefreshRate: nil,
                usesDisplayRefreshCadence: true
            ) != .zero
        )
    }

    @Test("Virtual display SCK queue depth separates low latency from smoothest at 60 Hz")
    func virtualDisplaySCKQueueDepthSeparatesLowLatencyFromSmoothestAt60Hz() {
        #expect(
            WindowCaptureEngine.resolveSCKQueueDepth(
                width: 2752,
                height: 2064,
                frameRate: 60,
                latencyMode: .lowestLatency,
                overrideDepth: nil,
                usesDisplayRefreshCadence: true
            ) == 3
        )
        #expect(
            WindowCaptureEngine.resolveSCKQueueDepth(
                width: 2752,
                height: 2064,
                frameRate: 60,
                latencyMode: .smoothest,
                overrideDepth: nil,
                usesDisplayRefreshCadence: true
            ) == 8
        )
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

    @Test("Repeated display-time cadence falls back to monotonic capture time")
    func repeatedDisplayTimeCadenceFallsBackToMonotonicCaptureTime() {
        let timestamp = CaptureStreamOutput.resolvedCadenceTimestamp(
            displayTimeSeconds: 42.0,
            presentationSeconds: 41.0,
            captureTime: 100.0,
            lastAdmittedTimestamp: 42.0
        )

        #expect(timestamp == 100.0)
    }

    @Test("Fresh display-time cadence remains preferred")
    func freshDisplayTimeCadenceRemainsPreferred() {
        let timestamp = CaptureStreamOutput.resolvedCadenceTimestamp(
            displayTimeSeconds: 42.017,
            presentationSeconds: 100.0,
            captureTime: 200.0,
            lastAdmittedTimestamp: 42.0
        )

        #expect(timestamp == 42.017)
    }
}
#endif
