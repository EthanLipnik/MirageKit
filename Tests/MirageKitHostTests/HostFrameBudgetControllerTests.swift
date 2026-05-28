//
//  HostFrameBudgetControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host Frame Budget Controller")
struct HostFrameBudgetControllerTests {
    @Test("Frame budget calculation uses active ceiling and requested FPS")
    func frameBudgetCalculationUsesActiveCeilingAndRequestedFPS() throws {
        var controller = HostFrameBudgetController()

        let optionalDecision = controller.update(
            with: feedback(sequence: 1),
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let decision = try #require(optionalDecision)

        #expect(decision.targetBitrateBps == 60_000_000)
        #expect(decision.maxFrameBytes == 125_000)
        #expect(decision.maxWireBytes == 125_000)
        #expect(decision.maxPacketCount == 95)
        #expect(abs(decision.sendDeadline - (10 + 1.0 / 60.0)) < 0.0001)
    }

    @Test("Over-budget P-frame is dropped and cuts quality immediately")
    func overBudgetPFrameIsDroppedAndCutsQualityImmediately() throws {
        var controller = HostFrameBudgetController()

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 130_000,
            wireBytes: 130_000,
            packetCount: 99,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .dropPFrameAndRequestKeyframe)
        #expect(evaluation.isOverBudget)
        #expect(decision.reason == .encodedFrame)
        #expect(decision.state == .pressured)
        #expect(decision.targetBitrateBps == 37_200_000)
        #expect(decision.quality < 0.8)
        #expect(decision.qualityCeiling == 0.624)
        #expect(controller.runtimeCeilingBps == decision.targetBitrateBps)
    }

    @Test("Wire and packet budgets are hard admission limits")
    func wireAndPacketBudgetsAreHardAdmissionLimits() throws {
        var controller = HostFrameBudgetController()

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 120_000,
            wireBytes: 130_000,
            packetCount: 100,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .dropPFrameAndRequestKeyframe)
        #expect(evaluation.byteRatio < 1.0)
        #expect(evaluation.wireRatio > 1.0)
        #expect(evaluation.packetRatio > 1.0)
        #expect(decision.reason == .encodedFrame)
    }

    @Test("Quality does not raise until consecutive clean frames")
    func qualityDoesNotRaiseUntilConsecutiveCleanFrames() throws {
        var controller = HostFrameBudgetController()

        let pressure = controller.evaluateEncodedFrame(
            byteCount: 130_000,
            wireBytes: 130_000,
            packetCount: 99,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 84_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let pressureDecision = try #require(pressure.budgetDecision)

        for index in 1 ... 7 {
            let clean = controller.evaluateEncodedFrame(
                byteCount: 20_000,
                wireBytes: 20_000,
                packetCount: 16,
                isKeyframe: false,
                receiverHealthy: true,
                currentBitrateBps: pressureDecision.targetBitrateBps,
                requestedTargetBitrateBps: 60_000_000,
                startupCeilingBps: 84_000_000,
                minimumBitrateFloorBps: 12_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_320,
                currentQuality: pressureDecision.quality,
                qualityFloor: 0.1,
                steadyQualityCeiling: 0.8,
                now: 10 + Double(index) * 0.1
            )
            #expect(clean.admission == .send)
            #expect(clean.budgetDecision == nil)
        }

        let raised = controller.evaluateEncodedFrame(
            byteCount: 20_000,
            wireBytes: 20_000,
            packetCount: 16,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: pressureDecision.targetBitrateBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 84_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: pressureDecision.quality,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10.9
        )
        let raisedDecision = try #require(raised.budgetDecision)

        #expect(raised.admission == .send)
        #expect(raisedDecision.reason == .healthy)
        #expect(raisedDecision.targetBitrateBps > pressureDecision.targetBitrateBps)
        #expect(raisedDecision.quality > pressureDecision.quality)
    }

    @Test("High-confidence change estimate lowers quality and encoder target")
    func highConfidenceChangeEstimateLowersQualityAndEncoderTarget() throws {
        var controller = HostFrameBudgetController()

        let optionalDecision = controller.updateForFrameChange(
            estimate: HostFrameChangeEstimate(
                changedAreaRatio: 0.72,
                averageDelta: 0.30,
                confidence: 0.96
            ),
            currentBitrateBps: 80_000_000,
            requestedTargetBitrateBps: 80_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let decision = try #require(optionalDecision)

        #expect(decision.reason == .frameChange)
        #expect(decision.state == .severe)
        #expect(decision.targetBitrateBps == 36_000_000)
        #expect(controller.runtimeCeilingBps == 36_000_000)
        #expect(decision.quality < 0.8)
    }

    @Test("Low-confidence change estimate is ignored")
    func lowConfidenceChangeEstimateIsIgnored() {
        var controller = HostFrameBudgetController()

        let decision = controller.updateForFrameChange(
            estimate: HostFrameChangeEstimate(
                changedAreaRatio: 0.92,
                averageDelta: 0.55,
                confidence: 0.50
            ),
            currentBitrateBps: 80_000_000,
            requestedTargetBitrateBps: 80_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        #expect(decision == nil)
        #expect(controller.runtimeCeilingBps == nil)
    }

    @Test("Motion estimate never overrides encoded-byte admission")
    func motionEstimateNeverOverridesEncodedByteAdmission() throws {
        var controller = HostFrameBudgetController()

        _ = controller.updateForFrameChange(
            estimate: HostFrameChangeEstimate(
                changedAreaRatio: 0.80,
                averageDelta: 0.36,
                confidence: 0.98
            ),
            currentBitrateBps: 80_000_000,
            requestedTargetBitrateBps: 80_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 170_000,
            wireBytes: 170_000,
            packetCount: 129,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 80_000_000,
            requestedTargetBitrateBps: 80_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.4,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10.1
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .dropPFrameAndRequestKeyframe)
        #expect(decision.reason == .encodedFrame)
        #expect(decision.targetBitrateBps < 80_000_000)
    }

    @Test("Recovery keyframe may use bounded multi-frame budget")
    func recoveryKeyframeMayUseBoundedMultiFrameBudget() throws {
        var controller = HostFrameBudgetController()

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 68_000,
            wireBytes: 76_000,
            packetCount: 58,
            isKeyframe: true,
            receiverHealthy: false,
            currentBitrateBps: 12_000_000,
            requestedTargetBitrateBps: 12_000_000,
            startupCeilingBps: 12_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.1,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .send)
        #expect(evaluation.isOverBudget)
        #expect(decision.state == .severe)
        #expect(decision.reason == .encodedFrame)
        #expect(decision.targetBitrateBps == 12_000_000)
        #expect(abs(evaluation.sendDeadline - (10 + 4.0 / 60.0)) < 0.0001)
    }

    @Test("Keyframe beyond recovery budget retries once at emergency quality then drops")
    func keyframeBeyondRecoveryBudgetRetriesOnceAtEmergencyQualityThenDrops() throws {
        var controller = HostFrameBudgetController()

        let first = controller.evaluateEncodedFrame(
            byteCount: 650_000,
            wireBytes: 650_000,
            packetCount: 493,
            isKeyframe: true,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let firstDecision = try #require(first.budgetDecision)

        #expect(first.admission == .retryKeyframeAtEmergencyQuality)
        #expect(firstDecision.quality < 0.8)
        #expect(firstDecision.keyframeQuality <= firstDecision.quality)

        let second = controller.evaluateEncodedFrame(
            byteCount: 650_000,
            wireBytes: 650_000,
            packetCount: 493,
            isKeyframe: true,
            receiverHealthy: true,
            currentBitrateBps: firstDecision.targetBitrateBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: firstDecision.keyframeQuality,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10.1
        )

        #expect(second.admission == .dropKeyframeAndWaitForNext)
        #expect(second.budgetDecision?.state == .severe)
    }

    @Test("Receiver feedback pressure lowers host-owned frame budget")
    func receiverFeedbackPressureLowersHostOwnedFrameBudget() throws {
        var controller = HostFrameBudgetController()

        let optionalDecision = controller.update(
            with: feedback(sequence: 1, pFrameCompletionLatencyP95Ms: 40),
            currentBitrateBps: 100_000_000,
            requestedTargetBitrateBps: 100_000_000,
            startupCeilingBps: 100_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let decision = try #require(optionalDecision)

        #expect(decision.state == .pressured)
        #expect(decision.reason == .pFrameLatency)
        #expect(decision.targetBitrateBps == 62_000_000)
        #expect(decision.maxFrameBytes == 129_166)
        #expect(decision.quality < 0.8)
    }

    private func feedback(
        sequence: UInt64,
        pFrameCompletionLatencyP95Ms: Double? = nil,
        receivedFPS: Double = 60,
        decodedFPS: Double = 60,
        rendererAcceptedFPS: Double = 60,
        rendererPresentedFPS: Double = 60,
        reassemblyBacklogFrames: Int = 0,
        reassemblyBacklogBytes: Int = 0,
        lostFrameCount: UInt64 = 0,
        discardedPacketCount: UInt64 = 0
    ) -> ReceiverMediaFeedbackMessage {
        ReceiverMediaFeedbackMessage(
            streamID: 1,
            sequence: sequence,
            sentAtUptime: 0,
            targetFPS: 60,
            ackRanges: [],
            lostFrameCount: lostFrameCount,
            discardedPacketCount: discardedPacketCount,
            jitterP95Ms: 0,
            jitterP99Ms: 0,
            queueEstimateFrames: 0,
            reassemblyBacklogFrames: reassemblyBacklogFrames,
            reassemblyBacklogKeyframes: 0,
            reassemblyBacklogBytes: reassemblyBacklogBytes,
            decodeBacklogFrames: 0,
            presentationBacklogFrames: 0,
            decodedFPS: decodedFPS,
            receivedFPS: receivedFPS,
            rendererAcceptedFPS: rendererAcceptedFPS,
            rendererPresentedFPS: rendererPresentedFPS,
            recoveryState: .idle,
            pFrameCompletionLatencyP50Ms: nil,
            pFrameCompletionLatencyP95Ms: pFrameCompletionLatencyP95Ms,
            pFrameCompletionLatencyMaxMs: nil,
            reassemblerForwardGapTimeouts: nil
        )
    }
}
#endif
