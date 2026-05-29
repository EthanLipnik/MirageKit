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

    @Test("Soft over-budget P-frame sends and cuts quality immediately")
    func softOverBudgetPFrameSendsAndCutsQualityImmediately() throws {
        var controller = HostFrameBudgetController()

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 155_000,
            wireBytes: 155_000,
            packetCount: 118,
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

        #expect(evaluation.admission == .sendWithQualityDrop)
        #expect(evaluation.isOverBudget)
        #expect(decision.reason == .encodedFrame)
        #expect(decision.state == .pressured)
        #expect(decision.targetBitrateBps == 60_000_000)
        #expect(decision.quality < 0.8)
        #expect(decision.qualityCeiling == 0.704)
        #expect(controller.runtimeCeilingBps == decision.targetBitrateBps)
    }

    @Test("Soft wire and packet budget overshoot sends while lowering quality")
    func softWireAndPacketBudgetOvershootSendsWhileLoweringQuality() throws {
        var controller = HostFrameBudgetController()

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 120_000,
            wireBytes: 155_000,
            packetCount: 118,
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

        #expect(evaluation.admission == .sendWithQualityDrop)
        #expect(evaluation.byteRatio < 1.0)
        #expect(evaluation.wireRatio > 1.0)
        #expect(evaluation.packetRatio > 1.0)
        #expect(decision.reason == .encodedFrame)
    }

    @Test("Major over-budget P-frame starts chain repair")
    func majorOverBudgetPFrameStartsChainRepair() throws {
        var controller = HostFrameBudgetController()

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 280_000,
            wireBytes: 280_000,
            packetCount: 213,
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

        #expect(evaluation.admission == .dropPFrameStartChainRepair)
        #expect(evaluation.byteRatio > 2.0)
        #expect(decision.reason == .encodedFrame)
        #expect(decision.state == .severe)
        #expect(decision.targetBitrateBps == 60_000_000)
    }

    @Test("Quality does not raise until consecutive clean frames")
    func qualityDoesNotRaiseUntilConsecutiveCleanFrames() throws {
        var controller = HostFrameBudgetController()

        let pressure = controller.evaluateEncodedFrame(
            byteCount: 155_000,
            wireBytes: 155_000,
            packetCount: 118,
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

        for index in 1 ... 3 {
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
            now: 10.5
        )
        let raisedDecision = try #require(raised.budgetDecision)

        #expect(raised.admission == .send)
        #expect(raisedDecision.reason == .healthy)
        #expect(raisedDecision.targetBitrateBps == pressureDecision.targetBitrateBps)
        #expect(raisedDecision.quality > pressureDecision.quality)
    }

    @Test("Healthy receiver feedback alone does not raise transport ceiling")
    func healthyReceiverFeedbackAloneDoesNotRaiseTransportCeiling() throws {
        var controller = HostFrameBudgetController()

        let optionalFirst = controller.update(
            with: feedback(sequence: 1),
            currentBitrateBps: 32_000_000,
            requestedTargetBitrateBps: 32_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let first = try #require(optionalFirst)

        let optionalSecond = controller.update(
            with: feedback(sequence: 2),
            currentBitrateBps: first.targetBitrateBps,
            requestedTargetBitrateBps: 32_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 11
        )
        let second = try #require(optionalSecond)

        #expect(second.targetBitrateBps == 32_000_000)
        #expect(controller.runtimeCeilingBps == 32_000_000)
    }

    @Test("Tiny clean frames at quality ceiling do not raise transport ceiling")
    func tinyCleanFramesAtQualityCeilingDoNotRaiseTransportCeiling() throws {
        var controller = HostFrameBudgetController()

        for index in 0 ..< 60 {
            let clean = controller.evaluateEncodedFrame(
                byteCount: 10_000,
                wireBytes: 10_000,
                packetCount: 8,
                isKeyframe: false,
                receiverHealthy: true,
                currentBitrateBps: 32_000_000,
                requestedTargetBitrateBps: 32_000_000,
                startupCeilingBps: 180_000_000,
                minimumBitrateFloorBps: 3_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_320,
                currentQuality: 0.8,
                qualityFloor: 0.05,
                steadyQualityCeiling: 0.8,
                now: 10 + Double(index) / 60.0
            )
            #expect(clean.admission == .send)
            #expect(clean.budgetDecision == nil)
        }

        #expect(controller.runtimeCeilingBps == 32_000_000)
    }

    @Test("Near-budget clean frames at quality ceiling can raise transport ceiling")
    func nearBudgetCleanFramesAtQualityCeilingCanRaiseTransportCeiling() throws {
        var controller = HostFrameBudgetController()

        for index in 0 ..< 23 {
            let clean = controller.evaluateEncodedFrame(
                byteCount: 50_000,
                wireBytes: 50_000,
                packetCount: 38,
                isKeyframe: false,
                receiverHealthy: true,
                currentBitrateBps: 32_000_000,
                requestedTargetBitrateBps: 32_000_000,
                startupCeilingBps: 180_000_000,
                minimumBitrateFloorBps: 3_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_320,
                currentQuality: 0.8,
                qualityFloor: 0.05,
                steadyQualityCeiling: 0.8,
                now: 10 + Double(index) / 60.0
            )
            #expect(clean.admission == .send)
            #expect(clean.budgetDecision == nil)
        }

        let raised = controller.evaluateEncodedFrame(
            byteCount: 50_000,
            wireBytes: 50_000,
            packetCount: 38,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 32_000_000,
            requestedTargetBitrateBps: 32_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10 + 23.0 / 60.0
        )
        let decision = try #require(raised.budgetDecision)

        #expect(raised.admission == .send)
        #expect(decision.reason == .healthy)
        #expect(decision.quality == 0.8)
        #expect(decision.targetBitrateBps == 34_560_000)
    }

    @Test("Modestly over-budget keyframe sends to preserve recovery")
    func modestlyOverBudgetKeyframeSendsToPreserveRecovery() throws {
        var controller = HostFrameBudgetController()

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 36_000,
            wireBytes: 36_000,
            packetCount: 30,
            isKeyframe: true,
            receiverHealthy: false,
            currentBitrateBps: 14_400_000,
            requestedTargetBitrateBps: 14_400_000,
            startupCeilingBps: 14_400_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.1,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .sendWithQualityDrop)
        #expect(evaluation.isOverBudget)
        #expect(evaluation.byteRatio <= 2.25)
        #expect(decision.reason == .encodedFrame)
    }

    @Test("Bounded emergency recovery keyframe can send at transport floor")
    func boundedEmergencyRecoveryKeyframeCanSendAtTransportFloor() throws {
        var controller = HostFrameBudgetController()

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 10_600,
            wireBytes: 13_240,
            packetCount: 11,
            isKeyframe: true,
            isRecoveryKeyframe: true,
            receiverHealthy: false,
            currentBitrateBps: 3_000_000,
            requestedTargetBitrateBps: 76_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.05,
            qualityFloor: 0.02,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .sendWithQualityDrop)
        #expect(evaluation.isOverBudget)
        #expect(evaluation.byteRatio > 1.0)
        #expect(decision.reason == .encodedFrame)
        #expect(decision.state == .severe)
        #expect(decision.targetBitrateBps == 3_000_000)
    }

    @Test("Large recovery keyframe retries instead of sending oversized burst")
    func largeRecoveryKeyframeRetriesInsteadOfSendingOversizedBurst() throws {
        var controller = HostFrameBudgetController()

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 66_000,
            wireBytes: 74_000,
            packetCount: 57,
            isKeyframe: true,
            isRecoveryKeyframe: true,
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

        #expect(evaluation.admission == .retryEmergencyKeyframeLowerQuality)
        #expect(evaluation.isOverBudget)
        #expect(decision.state == .severe)
        #expect(decision.reason == .encodedFrame)
        #expect(decision.targetBitrateBps == 12_000_000)
        #expect(abs(evaluation.sendDeadline - (10 + 1.0 / 60.0)) < 0.0001)
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

        #expect(first.admission == .retryEmergencyKeyframeLowerQuality)
        #expect(firstDecision.quality < 0.8)
        #expect(firstDecision.keyframeQuality <= firstDecision.quality)
        #expect(firstDecision.targetBitrateBps == 60_000_000)

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

        #expect(second.admission == .dropKeyframeWaitForNextLatestFrame)
        #expect(second.budgetDecision?.state == .severe)
    }

    @Test("P-frame latency alone holds ceiling and quality")
    func pFrameLatencyAloneHoldsCeilingAndQuality() throws {
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

        #expect(decision.state == .observing)
        #expect(decision.reason == .healthy)
        #expect(decision.targetBitrateBps == 100_000_000)
        #expect(decision.maxFrameBytes == 208_333)
        #expect(decision.quality == 0.8)
        #expect(controller.runtimeCeilingBps == 100_000_000)
    }

    @Test("P-frame latency alone does not block clean-frame quality raise")
    func pFrameLatencyAloneDoesNotBlockCleanFrameQualityRaise() throws {
        var controller = HostFrameBudgetController()

        _ = controller.update(
            with: feedback(sequence: 1, pFrameCompletionLatencyP95Ms: 45),
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.4,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        for index in 1 ... 3 {
            let clean = controller.evaluateEncodedFrame(
                byteCount: 20_000,
                wireBytes: 20_000,
                packetCount: 16,
                isKeyframe: false,
                receiverHealthy: true,
                currentBitrateBps: 60_000_000,
                requestedTargetBitrateBps: 60_000_000,
                startupCeilingBps: 60_000_000,
                minimumBitrateFloorBps: 12_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_320,
                currentQuality: 0.4,
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
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 12_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.4,
            qualityFloor: 0.1,
            steadyQualityCeiling: 0.8,
            now: 10.5
        )
        let decision = try #require(raised.budgetDecision)

        #expect(decision.reason == .healthy)
        #expect(decision.quality > 0.4)
    }

    @Test("P-frame latency plus backlog can lower ceiling")
    func pFrameLatencyPlusBacklogCanLowerCeiling() throws {
        var controller = HostFrameBudgetController()

        let optionalDecision = controller.update(
            with: feedback(
                sequence: 1,
                pFrameCompletionLatencyP95Ms: 55,
                reassemblyBacklogFrames: 3
            ),
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

        #expect(decision.state == .severe)
        #expect(decision.reason == .pFrameLatency)
        #expect(decision.targetBitrateBps == 45_000_000)
        #expect(controller.runtimeCeilingBps == 45_000_000)
        #expect(decision.quality < 0.8)
    }

    @Test("Receiver cadence alone cannot cut bitrate ceiling")
    func receiverCadenceAloneCannotCutBitrateCeiling() throws {
        var controller = HostFrameBudgetController()

        let optionalDecision = controller.update(
            with: feedback(
                sequence: 1,
                receivedFPS: 60,
                decodedFPS: 60,
                rendererAcceptedFPS: 60,
                rendererPresentedFPS: 24
            ),
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
        #expect(decision.reason == .receiverCadence)
        #expect(decision.targetBitrateBps == 100_000_000)
        #expect(controller.runtimeCeilingBps == 100_000_000)
    }

    @Test("Receiver cadence plus reassembly backlog can cut ceiling")
    func receiverCadencePlusReassemblyBacklogCanCutCeiling() throws {
        var controller = HostFrameBudgetController()

        let optionalDecision = controller.update(
            with: feedback(
                sequence: 1,
                receivedFPS: 60,
                decodedFPS: 60,
                rendererAcceptedFPS: 60,
                rendererPresentedFPS: 24,
                reassemblyBacklogFrames: 3
            ),
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
        #expect(decision.reason == .receiverBacklog)
        #expect(decision.targetBitrateBps == 68_000_000)
        #expect(controller.runtimeCeilingBps == 68_000_000)
    }

    @Test("Low received cadence alone cannot cut bitrate ceiling")
    func lowReceivedCadenceAloneCannotCutBitrateCeiling() throws {
        var controller = HostFrameBudgetController()

        let optionalDecision = controller.update(
            with: feedback(
                sequence: 1,
                receivedFPS: 9,
                decodedFPS: 9,
                rendererAcceptedFPS: 9,
                rendererPresentedFPS: 9,
                jitterP95Ms: 210,
                jitterP99Ms: 232,
                receivedWorstGapMs: 300
            ),
            currentBitrateBps: 180_000_000,
            requestedTargetBitrateBps: 180_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let decision = try #require(optionalDecision)

        #expect(decision.state == .pressured)
        #expect(decision.reason == .receiverCadence)
        #expect(decision.targetBitrateBps == 180_000_000)
        #expect(controller.runtimeCeilingBps == 180_000_000)
    }

    private func feedback(
        sequence: UInt64,
        pFrameCompletionLatencyP95Ms: Double? = nil,
        receivedFPS: Double = 60,
        decodedFPS: Double = 60,
        rendererAcceptedFPS: Double = 60,
        rendererPresentedFPS: Double = 60,
        jitterP95Ms: Double = 0,
        jitterP99Ms: Double = 0,
        receivedWorstGapMs: Double? = nil,
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
            jitterP95Ms: jitterP95Ms,
            jitterP99Ms: jitterP99Ms,
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
            receivedWorstGapMs: receivedWorstGapMs,
            reassemblerForwardGapTimeouts: nil
        )
    }
}
#endif
