//
//  HostAdaptivePFrameControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/29/26.
//

#if os(macOS)
import CoreFoundation
@testable import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host Adaptive P-frame Controller")
struct HostAdaptivePFrameControllerTests {
    @Test("Local send completion cannot learn or raise capacity")
    func localSendCompletionCannotLearnOrRaiseCapacity() {
        var controller = HostAdaptivePFrameController()

        let decision = controller.recordFrameTransportCompletion(
            frameNumber: 10,
            wireBytes: 30_000,
            packetCount: 23,
            isKeyframe: false,
            sendCompletionMs: 5,
            timingSource: .localSendCompletion,
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
            now: 10
        )

        #expect(decision == nil)
        #expect(controller.runtimeCeilingBps == nil)
        #expect(controller.recentCleanPFrameBaselineWireBytes == nil)
    }

    @Test("Keyframe samples are ignored by P-frame learning")
    func keyframeSamplesAreIgnoredByPFrameLearning() {
        var controller = HostAdaptivePFrameController()

        let decision = controller.recordFrameTransportCompletion(
            frameNumber: 1,
            wireBytes: 220_000,
            packetCount: 168,
            isKeyframe: true,
            sendCompletionMs: 45,
            timingSource: .clientAssembled,
            receiverHealthy: false,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        #expect(decision == nil)
        #expect(controller.runtimeCeilingBps == nil)
        #expect(controller.recentCleanPFrameBaselineWireBytes == nil)
    }

    @Test("One slow receiver P-frame timing sample does not collapse ceiling")
    func oneSlowReceiverPFrameTimingSampleDoesNotCollapseCeiling() throws {
        var controller = HostAdaptivePFrameController()

        let decision = controller.recordFrameTransportCompletion(
            frameNumber: 20,
            wireBytes: 80_000,
            packetCount: 61,
            isKeyframe: false,
            sendCompletionMs: 25,
            timingSource: .clientAssembled,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        #expect(controller.transportCeilingWireBytes == 58_515)
        #expect(controller.runtimeCeilingBps == 28_087_200)
        #expect(abs(controller.holdDownUntil) < 0.0001)
        #expect(decision == nil)
    }

    @Test("Two of three bad receiver P-frame timing samples lower ceiling with mild cap")
    func twoOfThreeBadReceiverPFrameTimingSamplesLowerCeilingWithMildCap() throws {
        var controller = HostAdaptivePFrameController()

        _ = controller.recordFrameTransportCompletion(
            frameNumber: 20,
            wireBytes: 80_000,
            packetCount: 61,
            isKeyframe: false,
            sendCompletionMs: 25,
            timingSource: .clientAssembled,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let optionalDecision = controller.recordFrameTransportCompletion(
            frameNumber: 21,
            wireBytes: 80_000,
            packetCount: 61,
            isKeyframe: false,
            sendCompletionMs: 25,
            timingSource: .clientAssembled,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
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
        #expect(decision.reason == .pFrameLatency)
        #expect(decision.targetBitrateBps == 23_873_760)
        #expect(controller.runtimeCeilingBps == 23_873_760)
        #expect(abs(controller.holdDownUntil - 25) < 0.0001)
        #expect(decision.quality < 0.8)
    }

    @Test("Two severe receiver P-frame timing samples can apply severe cap")
    func twoSevereReceiverPFrameTimingSamplesCanApplySevereCap() throws {
        var controller = HostAdaptivePFrameController()

        _ = controller.recordFrameTransportCompletion(
            frameNumber: 20,
            wireBytes: 80_000,
            packetCount: 61,
            isKeyframe: false,
            sendCompletionMs: 35,
            timingSource: .clientAssembled,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let optionalDecision = controller.recordFrameTransportCompletion(
            frameNumber: 21,
            wireBytes: 80_000,
            packetCount: 61,
            isKeyframe: false,
            sendCompletionMs: 35,
            timingSource: .clientAssembled,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
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

        #expect(decision.state == .severe)
        #expect(decision.reason == .pFrameLatency)
        #expect(decision.targetBitrateBps == 18_256_320)
        #expect(abs(controller.holdDownUntil - 40) < 0.0001)
    }

    @Test("Receiver timing cuts cannot compound inside one feedback batch")
    func receiverTimingCutsCannotCompoundInsideOneFeedbackBatch() throws {
        var controller = HostAdaptivePFrameController()

        _ = controller.recordFrameTransportCompletion(
            frameNumber: 20,
            wireBytes: 80_000,
            packetCount: 61,
            isKeyframe: false,
            sendCompletionMs: 25,
            timingSource: .clientAssembled,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        _ = controller.recordFrameTransportCompletion(
            frameNumber: 21,
            wireBytes: 80_000,
            packetCount: 61,
            isKeyframe: false,
            sendCompletionMs: 25,
            timingSource: .clientAssembled,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let afterFirstCut = try #require(controller.transportCeilingWireBytes)

        _ = controller.recordFrameTransportCompletion(
            frameNumber: 22,
            wireBytes: 80_000,
            packetCount: 61,
            isKeyframe: false,
            sendCompletionMs: 25,
            timingSource: .clientAssembled,
            receiverHealthy: true,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        #expect(controller.transportCeilingWireBytes == afterFirstCut)
    }

    @Test("Unhealthy receiver timing cannot cut transport ceiling")
    func unhealthyReceiverTimingCannotCutTransportCeiling() {
        var controller = HostAdaptivePFrameController()

        for frameNumber in 20 ... 22 {
            _ = controller.recordFrameTransportCompletion(
                frameNumber: UInt64(frameNumber),
                wireBytes: 80_000,
                packetCount: 61,
                isKeyframe: false,
                sendCompletionMs: 35,
                timingSource: .clientAssembled,
                receiverHealthy: false,
                currentBitrateBps: 60_000_000,
                requestedTargetBitrateBps: 60_000_000,
                startupCeilingBps: 180_000_000,
                minimumBitrateFloorBps: 3_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_320,
                currentQuality: 0.8,
                qualityFloor: 0.05,
                steadyQualityCeiling: 0.8,
                now: 10
            )
        }

        #expect(controller.runtimeCeilingBps == 28_087_200)
        #expect(abs(controller.holdDownUntil) < 0.0001)
    }

    @Test("Quarantined receiver timing cannot cut transport ceiling")
    func quarantinedReceiverTimingCannotCutTransportCeiling() {
        var controller = HostAdaptivePFrameController()

        for frameNumber in 20 ... 22 {
            _ = controller.recordFrameTransportCompletion(
                frameNumber: UInt64(frameNumber),
                wireBytes: 80_000,
                packetCount: 61,
                isKeyframe: false,
                sendCompletionMs: 35,
                timingSource: .clientAssembled,
                receiverHealthy: true,
                capacityLearningAllowed: false,
                capacityLearningQuarantineReason: "decode-backlog",
                currentBitrateBps: 60_000_000,
                requestedTargetBitrateBps: 60_000_000,
                startupCeilingBps: 180_000_000,
                minimumBitrateFloorBps: 3_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_320,
                currentQuality: 0.8,
                qualityFloor: 0.05,
                steadyQualityCeiling: 0.8,
                now: 10
            )
        }

        #expect(controller.runtimeCeilingBps == 28_087_200)
        #expect(abs(controller.holdDownUntil) < 0.0001)
    }

    @Test("Tiny slow P-frame timing does not learn a low transport ceiling")
    func tinySlowPFrameTimingDoesNotLearnLowTransportCeiling() {
        var controller = HostAdaptivePFrameController()

        let decision = controller.recordFrameTransportCompletion(
            frameNumber: 22,
            wireBytes: 1_024,
            packetCount: 1,
            isKeyframe: false,
            sendCompletionMs: 80,
            timingSource: .clientAssembled,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        #expect(decision == nil)
        #expect(controller.runtimeCeilingBps == 28_087_200)
        #expect(abs(controller.holdDownUntil) < 0.0001)
    }

    @Test("Clean P-frame baseline requires multiple receiver-confirmed non-tiny samples")
    func cleanPFrameBaselineRequiresMultipleReceiverConfirmedNonTinySamples() {
        var controller = HostAdaptivePFrameController()

        _ = recordReceiverCleanPFrame(controller: &controller, frameNumber: 30, wireBytes: 4_000, packetCount: 4, now: 10)
        _ = recordReceiverCleanPFrame(controller: &controller, frameNumber: 31, wireBytes: 30_000, packetCount: 23, now: 10.1)
        _ = recordReceiverCleanPFrame(controller: &controller, frameNumber: 32, wireBytes: 32_000, packetCount: 25, now: 10.2)
        #expect(controller.recentCleanPFrameBaselineWireBytes == nil)

        _ = recordReceiverCleanPFrame(controller: &controller, frameNumber: 33, wireBytes: 31_000, packetCount: 24, now: 10.3)
        #expect(controller.recentCleanPFrameBaselineWireBytes == 31_000)
        #expect(controller.recentCleanPFrameBaselinePacketCount == 24)
    }

    @Test("Clean under-target P-frame raises quality per frame")
    func cleanUnderTargetPFrameRaisesQualityPerFrame() throws {
        var controller = HostAdaptivePFrameController()

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 20_000,
            wireBytes: 20_000,
            packetCount: 16,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.50,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .send)
        #expect(decision.reason == .healthy)
        #expect(abs(decision.quality - 0.65) < 0.001)
        #expect(controller.runtimeCeilingBps == 28_087_200)
    }

    @Test("Under-target P-frame with unhealthy receiver sends without quality cut")
    func underTargetPFrameWithUnhealthyReceiverSendsWithoutQualityCut() {
        var controller = HostAdaptivePFrameController()

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 1_024,
            wireBytes: 1_024,
            packetCount: 1,
            isKeyframe: false,
            receiverHealthy: false,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.30,
            qualityFloor: 0.02,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        #expect(evaluation.admission == .send)
        #expect(evaluation.budgetDecision == nil)
    }

    @Test("Tiny relative P-frame change under target does not cut quality")
    func tinyRelativePFrameChangeUnderTargetDoesNotCutQuality() {
        var controller = HostAdaptivePFrameController()
        seedCleanBaseline(controller: &controller, wireBytes: 8_700, packetCount: 7)

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 9_200,
            wireBytes: 9_200,
            packetCount: 8,
            isKeyframe: false,
            receiverHealthy: false,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.30,
            qualityFloor: 0.02,
            steadyQualityCeiling: 0.8,
            now: 11
        )

        #expect(evaluation.admission == .send)
        #expect(evaluation.budgetDecision == nil)
    }

    @Test("Under-ceiling P-frame growth cuts next quality without chain repair")
    func underCeilingPFrameGrowthCutsNextQualityWithoutChainRepair() throws {
        var controller = HostAdaptivePFrameController()
        _ = controller.evaluateEncodedFrame(
            byteCount: 30_000,
            wireBytes: 30_000,
            packetCount: 23,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.40,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 34_000,
            wireBytes: 34_000,
            packetCount: 26,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.40,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10.1
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .sendWithQualityDrop)
        #expect(decision.reason == .encodedFrame)
        #expect(decision.quality < 0.40)
        #expect(evaluation.wireRatio < 1.0)
    }

    @Test("Same or smaller P-frame raises quality every frame")
    func sameOrSmallerPFrameRaisesQualityEveryFrame() throws {
        var controller = HostAdaptivePFrameController()
        _ = controller.evaluateEncodedFrame(
            byteCount: 30_000,
            wireBytes: 30_000,
            packetCount: 23,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.30,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 29_000,
            wireBytes: 29_000,
            packetCount: 22,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.30,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10.1
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .send)
        #expect(decision.reason == .healthy)
        #expect(decision.quality > 0.30)
    }

    @Test("Quality probe growth does not immediately cut quality")
    func qualityProbeGrowthDoesNotImmediatelyCutQuality() {
        var controller = HostAdaptivePFrameController()
        _ = controller.evaluateEncodedFrame(
            byteCount: 30_000,
            wireBytes: 30_000,
            packetCount: 23,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.30,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 34_000,
            wireBytes: 34_000,
            packetCount: 26,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.38,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10.1
        )

        #expect(evaluation.admission == .send)
        #expect(evaluation.budgetDecision == nil)
    }

    @Test("Large growth during quality probe still cuts next quality")
    func largeGrowthDuringQualityProbeStillCutsNextQuality() throws {
        var controller = HostAdaptivePFrameController()
        _ = controller.evaluateEncodedFrame(
            byteCount: 30_000,
            wireBytes: 30_000,
            packetCount: 23,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.30,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 42_000,
            wireBytes: 42_000,
            packetCount: 32,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.38,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10.1
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .sendWithQualityDrop)
        #expect(decision.reason == .encodedFrame)
        #expect(decision.quality < 0.38)
    }

    @Test("Ceiling probes by five percent after hold-down")
    func ceilingProbesByFivePercentAfterHoldDown() throws {
        var controller = HostAdaptivePFrameController()
        _ = recordReceiverCleanPFrame(controller: &controller, frameNumber: 40, wireBytes: 30_000, packetCount: 23, now: 10)
        _ = recordReceiverCleanPFrame(controller: &controller, frameNumber: 41, wireBytes: 30_500, packetCount: 23, now: 10.1)
        _ = recordReceiverCleanPFrame(controller: &controller, frameNumber: 42, wireBytes: 30_000, packetCount: 23, now: 10.2)
        let before = try #require(controller.transportCeilingWireBytes)

        let optionalDecision = recordReceiverCleanPFrame(
            controller: &controller,
            frameNumber: 43,
            wireBytes: 25_000,
            packetCount: 20,
            now: 11
        )
        let decision = try #require(optionalDecision)

        #expect(decision.reason == .healthy)
        #expect(controller.transportCeilingWireBytes == Int((Double(before) * 1.05).rounded(.up)))
    }

    @Test("Log-scaled spike ratio shrinks for larger clean baselines")
    func logScaledSpikeRatioShrinksForLargerCleanBaselines() {
        #expect(abs(HostAdaptivePFrameController.allowedPFrameSpikeRatio(baselineWireBytes: 13 * 1024) - 3.5) < 0.001)
        #expect(abs(HostAdaptivePFrameController.allowedPFrameSpikeRatio(baselineWireBytes: 128 * 1024) - 2.45) < 0.001)
        #expect(abs(HostAdaptivePFrameController.allowedPFrameSpikeRatio(baselineWireBytes: 512 * 1024) - 1.75) < 0.001)
        #expect(abs(HostAdaptivePFrameController.allowedPFrameSpikeRatio(baselineWireBytes: 2 * 1024 * 1024) - 1.25) < 0.001)
        #expect(HostAdaptivePFrameController.allowedPFrameSpikePacketCount(
            baselinePacketCount: 10,
            allowedSpikeRatio: 3.5
        ) == 35)
        #expect(HostAdaptivePFrameController.allowedPFrameSpikePacketCount(
            baselinePacketCount: 2,
            allowedSpikeRatio: 3.5
        ) == 10)
    }

    @Test("Twelve KB to thirty-nine KB P-frame sends and cuts next quality")
    func twelveKBToThirtyNineKBPFrameSendsAndCutsNextQuality() throws {
        var controller = HostAdaptivePFrameController()
        seedCleanBaseline(controller: &controller, wireBytes: 12 * 1024, packetCount: 10)
        _ = controller.evaluateEncodedFrame(
            byteCount: 12 * 1024,
            wireBytes: 12 * 1024,
            packetCount: 10,
            isKeyframe: false,
            adaptiveKeyframeAllowed: true,
            receiverHealthy: true,
            senderHealthy: true,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10.9
        )

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 39 * 1024,
            wireBytes: 39 * 1024,
            packetCount: 31,
            isKeyframe: false,
            adaptiveKeyframeAllowed: true,
            receiverHealthy: true,
            senderHealthy: true,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 11
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .sendWithQualityDrop)
        #expect(decision.quality <= 0.29)
        #expect(decision.reason == .encodedFrame)
    }

    @Test("Under-ceiling P-frame sends even when relative threshold is exceeded")
    func underCeilingPFrameSendsEvenWhenRelativeThresholdIsExceeded() {
        var controller = HostAdaptivePFrameController()
        seedCleanBaseline(controller: &controller, wireBytes: 9 * 1024, packetCount: 8)

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 36 * 1024,
            wireBytes: 36 * 1024,
            packetCount: 28,
            isKeyframe: false,
            adaptiveKeyframeAllowed: true,
            receiverHealthy: true,
            senderHealthy: true,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 11
        )

        #expect(evaluation.admission == .send)
        #expect(evaluation.wireRatio < 1.0)
    }

    @Test("Large MB-scale spike starts adaptive repair and records geometric target")
    func largeMBScaleSpikeStartsAdaptiveRepairAndRecordsGeometricTarget() throws {
        var controller = HostAdaptivePFrameController()
        seedCleanBaseline(
            controller: &controller,
            wireBytes: 12 * 1024 * 1024,
            packetCount: 10_000,
            currentBitrateBps: 10_000_000_000,
            startupCeilingBps: 10_000_000_000
        )

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 39 * 1024 * 1024,
            wireBytes: 39 * 1024 * 1024,
            packetCount: 32_000,
            isKeyframe: false,
            adaptiveKeyframeAllowed: true,
            receiverHealthy: true,
            senderHealthy: true,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 10_000_000_000,
            startupCeilingBps: 10_000_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 11
        )

        let repairTarget = try #require(controller.adaptiveRepairTargetWireBytes)
        #expect(evaluation.admission == .dropPFrameStartChainRepair)
        #expect(repairTarget > 18 * 1024 * 1024)
        #expect(repairTarget < 23 * 1024 * 1024)
    }

    @Test("Major spike during cooldown preserves chain with quality drop")
    func majorSpikeDuringCooldownPreservesChainWithQualityDrop() throws {
        var controller = HostAdaptivePFrameController()
        seedCleanBaseline(
            controller: &controller,
            wireBytes: 12 * 1024 * 1024,
            packetCount: 10_000,
            currentBitrateBps: 10_000_000_000,
            startupCeilingBps: 10_000_000_000
        )

        let evaluation = controller.evaluateEncodedFrame(
            byteCount: 39 * 1024 * 1024,
            wireBytes: 39 * 1024 * 1024,
            packetCount: 32_000,
            isKeyframe: false,
            adaptiveKeyframeAllowed: false,
            receiverHealthy: true,
            senderHealthy: true,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 10_000_000_000,
            startupCeilingBps: 10_000_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 11
        )
        let decision = try #require(evaluation.budgetDecision)

        #expect(evaluation.admission == .sendWithQualityDrop)
        #expect(decision.quality <= 0.29)
    }

    @Test("Over-target recovery keyframe retries lower scale")
    func overTargetRecoveryKeyframeRetriesLowerScale() {
        var controller = HostAdaptivePFrameController()
        seedCleanBaseline(controller: &controller, wireBytes: 30_000, packetCount: 23)
        _ = controller.evaluateEncodedFrame(
            byteCount: 400_000,
            wireBytes: 400_000,
            packetCount: 304,
            isKeyframe: false,
            adaptiveKeyframeAllowed: true,
            receiverHealthy: false,
            senderHealthy: false,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10.8
        )

        let keyframeEvaluation = controller.evaluateEncodedFrame(
            byteCount: 200_000,
            wireBytes: 200_000,
            packetCount: 152,
            isKeyframe: true,
            isRecoveryKeyframe: true,
            receiverHealthy: false,
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.2,
            qualityFloor: 0.02,
            steadyQualityCeiling: 0.8,
            now: 11
        )

        #expect(keyframeEvaluation.admission == .dropKeyframeRetryLowerScale)
    }

    @Test("Receiver loss cuts ceiling but encoded size alone does not")
    func receiverLossCutsCeilingButEncodedSizeAloneDoesNot() throws {
        var controller = HostAdaptivePFrameController()
        _ = controller.evaluateEncodedFrame(
            byteCount: 39 * 1024,
            wireBytes: 39 * 1024,
            packetCount: 31,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let before = try #require(controller.transportCeilingWireBytes)

        let optionalDecision = controller.update(
            with: feedback(sequence: 1, lostFrameCount: 1),
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 11
        )
        _ = try #require(optionalDecision)

        #expect(controller.transportCeilingWireBytes == Int((Double(before) * 0.80).rounded(.down)))
    }

    @Test("Client recovery feedback alone does not floor quality or ceiling")
    func clientRecoveryFeedbackAloneDoesNotFloorQualityOrCeiling() throws {
        var controller = HostAdaptivePFrameController()
        _ = controller.evaluateEncodedFrame(
            byteCount: 20_000,
            wireBytes: 20_000,
            packetCount: 16,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let before = try #require(controller.transportCeilingWireBytes)

        let decision = controller.update(
            with: feedback(sequence: 1, recoveryState: .keyframeRecovery),
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 11
        )

        #expect(decision == nil)
        #expect(controller.transportCeilingWireBytes == before)
    }

    @Test("Receiver backlog alone holds raises without cutting ceiling")
    func receiverBacklogAloneHoldsRaisesWithoutCuttingCeiling() throws {
        var controller = HostAdaptivePFrameController()
        _ = controller.evaluateEncodedFrame(
            byteCount: 20_000,
            wireBytes: 20_000,
            packetCount: 16,
            isKeyframe: false,
            receiverHealthy: true,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 10
        )
        let before = try #require(controller.transportCeilingWireBytes)

        let decision = controller.update(
            with: feedback(sequence: 1, reassemblyBacklogFrames: 5),
            currentBitrateBps: controller.runtimeCeilingBps,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: 11
        )

        #expect(decision == nil)
        #expect(controller.transportCeilingWireBytes == before)
    }

    @Test("Freshness snapshot does not hold for one fresh unstarted P-frame")
    func freshnessSnapshotDoesNotHoldForOneFreshUnstartedPFrame() {
        let freshSnapshot = StreamPacketSender.FreshnessSnapshot(
            queuedBytes: 20_000,
            unstartedPFrameCount: 1,
            oldestUnstartedPFrameAgeMs: 2,
            oldestUnstartedPFrameLatenessMs: 0,
            lateReservedPFrameStreak: 0
        )
        let staleSnapshot = StreamPacketSender.FreshnessSnapshot(
            queuedBytes: 20_000,
            unstartedPFrameCount: 1,
            oldestUnstartedPFrameAgeMs: 30,
            oldestUnstartedPFrameLatenessMs: 0,
            lateReservedPFrameStreak: 0
        )

        #expect(freshSnapshot.shouldHoldPFrameReservation(frameRate: 60) == false)
        #expect(staleSnapshot.shouldHoldPFrameReservation(frameRate: 60) == true)
    }

    private func seedCleanBaseline(
        controller: inout HostAdaptivePFrameController,
        wireBytes: Int,
        packetCount: Int,
        currentBitrateBps: Int = 60_000_000,
        startupCeilingBps: Int = 180_000_000
    ) {
        _ = recordReceiverCleanPFrame(
            controller: &controller,
            frameNumber: 90,
            wireBytes: wireBytes,
            packetCount: packetCount,
            currentBitrateBps: currentBitrateBps,
            startupCeilingBps: startupCeilingBps,
            now: 10
        )
        _ = recordReceiverCleanPFrame(
            controller: &controller,
            frameNumber: 91,
            wireBytes: wireBytes + max(1, wireBytes / 64),
            packetCount: packetCount + 1,
            currentBitrateBps: currentBitrateBps,
            startupCeilingBps: startupCeilingBps,
            now: 10.1
        )
        _ = recordReceiverCleanPFrame(
            controller: &controller,
            frameNumber: 92,
            wireBytes: wireBytes,
            packetCount: packetCount,
            currentBitrateBps: currentBitrateBps,
            startupCeilingBps: startupCeilingBps,
            now: 10.2
        )
    }

    private func recordReceiverCleanPFrame(
        controller: inout HostAdaptivePFrameController,
        frameNumber: UInt64,
        wireBytes: Int,
        packetCount: Int,
        currentBitrateBps: Int = 60_000_000,
        startupCeilingBps: Int = 180_000_000,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        controller.recordFrameTransportCompletion(
            frameNumber: frameNumber,
            wireBytes: wireBytes,
            packetCount: packetCount,
            isKeyframe: false,
            sendCompletionMs: 5,
            timingSource: .clientAssembled,
            receiverHealthy: true,
            currentBitrateBps: currentBitrateBps,
            requestedTargetBitrateBps: currentBitrateBps,
            startupCeilingBps: startupCeilingBps,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_320,
            currentQuality: 0.8,
            qualityFloor: 0.05,
            steadyQualityCeiling: 0.8,
            now: now
        )
    }

    private func feedback(
        sequence: UInt64,
        lostFrameCount: UInt64 = 0,
        discardedPacketCount: UInt64 = 0,
        reassemblyBacklogFrames: Int = 0,
        reassemblyBacklogBytes: Int = 0,
        recoveryState: MirageMediaFeedbackRecoveryState = .idle
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
            decodedFPS: 60,
            receivedFPS: 60,
            rendererAcceptedFPS: 60,
            rendererPresentedFPS: 60,
            recoveryState: recoveryState
        )
    }
}
#endif
