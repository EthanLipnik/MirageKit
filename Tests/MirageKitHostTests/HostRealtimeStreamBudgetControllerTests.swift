//
//  HostRealtimeStreamBudgetControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host Realtime Stream Budget Controller")
struct HostRealtimeStreamBudgetControllerTests {
    @Test("P-frame latency drops bitrate ceiling and quality ceiling without frame admission")
    func pFrameLatencyDropsRealtimeBudget() {
        var controller = HostRealtimeStreamBudgetController()

        let pressure = controller.update(
            with: feedback(sequence: 1, pFrameCompletionLatencyP95Ms: 55),
            currentBitrateBps: 100_000_000,
            requestedTargetBitrateBps: 100_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        #expect(pressure?.state == .pressured)
        #expect(pressure?.reason == "p-frame-latency")
        #expect(pressure?.targetBitrateBps == 85_000_000)
        #expect(abs(Double((pressure?.runtimeQualityCeiling ?? 0) - 0.68)) < 0.001)
        #expect(pressure?.frameAdmissionTargetFPS == nil)

        let severe = controller.update(
            with: feedback(sequence: 2, pFrameCompletionLatencyP95Ms: 90),
            currentBitrateBps: 85_000_000,
            requestedTargetBitrateBps: 100_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            steadyQualityCeiling: 0.8,
            now: 11
        )

        #expect(severe?.state == .severe)
        #expect(abs(Double((severe?.targetBitrateBps ?? 0) - 59_500_000)) <= 1)
        #expect(abs(Double((severe?.runtimeQualityCeiling ?? 0) - 0.56)) < 0.001)
        #expect(severe?.frameAdmissionTargetFPS == nil)
    }

    @Test("Receiver cadence alone does not lower realtime budget")
    func receiverCadenceAloneDoesNotLowerRealtimeBudget() {
        var controller = HostRealtimeStreamBudgetController()

        let pressure = controller.update(
            with: feedback(sequence: 1, receivedFPS: 23),
            currentBitrateBps: 100_000_000,
            requestedTargetBitrateBps: 100_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let persistentSample = controller.update(
            with: feedback(sequence: 2, receivedFPS: 23),
            currentBitrateBps: 100_000_000,
            requestedTargetBitrateBps: 100_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            steadyQualityCeiling: 0.8,
            now: 11.1
        )

        #expect(pressure?.state == .observing)
        #expect(pressure?.reason == "healthy")
        #expect(pressure?.frameAdmissionTargetFPS == nil)
        #expect(persistentSample?.state == .observing)
        #expect(persistentSample?.targetBitrateBps == nil)
        #expect(persistentSample?.runtimeQualityCeiling == nil)
        #expect(persistentSample?.frameAdmissionTargetFPS == nil)
    }

    @Test("Healthy samples raise recovered bitrate ceiling quickly")
    func healthySamplesRaiseRecoveredBitrateQuickly() {
        var controller = HostRealtimeStreamBudgetController()

        _ = controller.update(
            with: feedback(sequence: 1, pFrameCompletionLatencyP95Ms: 55),
            currentBitrateBps: 100_000_000,
            requestedTargetBitrateBps: 100_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        _ = controller.update(
            with: feedback(sequence: 2),
            currentBitrateBps: 85_000_000,
            requestedTargetBitrateBps: 100_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            steadyQualityCeiling: 0.8,
            now: 12
        )
        let raised = controller.update(
            with: feedback(sequence: 3),
            currentBitrateBps: 85_000_000,
            requestedTargetBitrateBps: 100_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            steadyQualityCeiling: 0.8,
            now: 12.7
        )

        #expect(raised?.state == .observing)
        #expect(raised?.targetBitrateBps == 100_000_000)
        #expect(raised?.runtimeQualityCeiling == nil)
        #expect(raised?.frameAdmissionTargetFPS == nil)
    }

    @Test("Cumulative forward gap counters do not stick realtime pressure")
    func cumulativeForwardGapCountersDoNotStickRealtimePressure() {
        var controller = HostRealtimeStreamBudgetController()

        let decision = controller.update(
            with: feedback(sequence: 1, reassemblerForwardGapTimeouts: 3),
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        #expect(decision?.state == .observing)
        #expect(decision?.targetBitrateBps == nil)
        #expect(decision?.runtimeQualityCeiling == nil)
        #expect(decision?.frameAdmissionTargetFPS == nil)
    }

    private func feedback(
        sequence: UInt64,
        pFrameCompletionLatencyP95Ms: Double? = nil,
        receivedFPS: Double = 60,
        reassemblerForwardGapTimeouts: UInt64? = nil
    ) -> ReceiverMediaFeedbackMessage {
        ReceiverMediaFeedbackMessage(
            streamID: 1,
            sequence: sequence,
            sentAtUptime: 0,
            targetFPS: 60,
            ackRanges: [],
            lostFrameCount: 0,
            discardedPacketCount: 0,
            jitterP95Ms: 0,
            jitterP99Ms: 0,
            queueEstimateFrames: 0,
            reassemblyBacklogFrames: 0,
            reassemblyBacklogKeyframes: 0,
            reassemblyBacklogBytes: 0,
            decodeBacklogFrames: 0,
            presentationBacklogFrames: 0,
            decodedFPS: 60,
            receivedFPS: receivedFPS,
            rendererAcceptedFPS: 60,
            rendererPresentedFPS: 60,
            recoveryState: .idle,
            pFrameCompletionLatencyP50Ms: nil,
            pFrameCompletionLatencyP95Ms: pFrameCompletionLatencyP95Ms,
            pFrameCompletionLatencyMaxMs: nil,
            reassemblerForwardGapTimeouts: reassemblerForwardGapTimeouts
        )
    }
}
#endif
