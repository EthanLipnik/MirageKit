//
//  HostAdaptivePFrameControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/31/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreFoundation
import MirageKit
import Testing

@Suite("Host Adaptive P-Frame Controller")
struct HostAdaptivePFrameControllerTests {
    @Test("Startup probe budget begins below automatic requested bitrate")
    func startupProbeBudgetBeginsBelowAutomaticRequestedBitrate() throws {
        var controller = HostAdaptivePFrameController()
        let requestedBitrate = 76_700_000

        let decision = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: requestedBitrate,
            requestedBitrate: requestedBitrate,
            startupCeiling: 180_000_000,
            minimumFloor: 3_000_000,
            inputActive: true,
            sourceStill: false,
            wireBytes: 40 * 1024,
            packetSpanMs: 3,
            completionGapMs: 3,
            currentQuality: 0.40
        ))

        #expect(decision.reason == .healthy)
        #expect(decision.maxWireBytes < frameBytes(for: requestedBitrate))
    }

    @Test("Clean underfilled receiver samples keep probing upward from startup budget")
    func cleanUnderfilledReceiverSamplesKeepProbingUpwardFromStartupBudget() throws {
        var controller = HostAdaptivePFrameController()
        let requestedBitrate = 76_700_000
        var currentBitrate = requestedBitrate
        var currentQuality: Float = 0.35
        var previousBudget = 0

        for frameNumber in 1...5 {
            let decision = try #require(recordDelivery(
                controller: &controller,
                frameNumber: UInt64(frameNumber),
                currentBitrate: currentBitrate,
                requestedBitrate: requestedBitrate,
                startupCeiling: 180_000_000,
                minimumFloor: 3_000_000,
                inputActive: true,
                sourceStill: false,
                wireBytes: 20 * 1024,
                packetSpanMs: 12,
                completionGapMs: 12,
                currentQuality: currentQuality,
                now: 10 + Double(frameNumber) * 0.02
            ))

            #expect(decision.reason == .healthy)
            if previousBudget > 0 {
                #expect(decision.maxWireBytes > previousBudget)
            }
            previousBudget = decision.maxWireBytes
            currentBitrate = decision.targetBitrateBps
            currentQuality = decision.quality
        }

        #expect(previousBudget > 64 * 1024)
    }

    @Test("One severe receiver delivery sample cuts immediately")
    func oneSevereReceiverDeliverySampleCutsImmediately() throws {
        var controller = HostAdaptivePFrameController()

        let decision = try #require(recordDelivery(
            controller: &controller,
            wireBytes: 240 * 1024,
            packetSpanMs: 80,
            completionGapMs: 80
        ))

        #expect(decision.reason == .pFrameLatency)
        #expect(decision.state == .severe)
        #expect(decision.maxWireBytes < frameBytes(for: 60_000_000))
    }

    @Test("Receiver pressure still cuts while capacity learning is paused")
    func receiverPressureStillCutsWhileCapacityLearningIsPaused() throws {
        var controller = HostAdaptivePFrameController()

        let decision = try #require(recordDelivery(
            controller: &controller,
            capacityLearningAllowed: false,
            wireBytes: 240 * 1024,
            packetSpanMs: 80,
            completionGapMs: 80
        ))

        #expect(decision.reason == .pFrameLatency)
        #expect(decision.state == .severe)
        #expect(decision.maxWireBytes < frameBytes(for: 60_000_000))
    }

    @Test("Clean samples do not raise quality while capacity learning is paused")
    func cleanSamplesDoNotRaiseQualityWhileCapacityLearningIsPaused() {
        var controller = HostAdaptivePFrameController()

        let decision = recordDelivery(
            controller: &controller,
            capacityLearningAllowed: false,
            wireBytes: 20 * 1024,
            packetSpanMs: 3,
            completionGapMs: 3,
            currentQuality: 0.40
        )

        #expect(decision == nil)
    }

    @Test("Timing cuts can fall below the old requested latency floor")
    func timingCutsCanFallBelowOldRequestedLatencyFloor() throws {
        var controller = HostAdaptivePFrameController()
        let requestedBitrate = 120_000_000
        let oldThirtyFivePercentFloorBytes = frameBytes(for: Int(Double(requestedBitrate) * 0.35))

        let decision = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: requestedBitrate,
            requestedBitrate: requestedBitrate,
            startupCeiling: requestedBitrate,
            minimumFloor: 2_000_000,
            wireBytes: frameBytes(for: requestedBitrate),
            packetSpanMs: 220,
            completionGapMs: 220
        ))

        #expect(decision.maxWireBytes < oldThirtyFivePercentFloorBytes)
        #expect(decision.maxWireBytes >= frameBytes(for: 2_000_000))
    }

    @Test("Mild Most Responsive oversize sends and cuts the next frame")
    func mildMostResponsiveOversizeSendsAndCutsNextFrame() throws {
        var controller = HostAdaptivePFrameController()
        let decision = controller.evaluateEncodedFrame(
            byteCount: 180 * 1024,
            wireBytes: 180 * 1024,
            packetCount: 154,
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 2_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            latencyMode: .lowestLatency,
            now: 10
        )

        #expect(decision.admission == .sendWithQualityDrop)
        #expect(decision.budgetDecision?.reason == .encodedFrame)
        #expect((decision.budgetDecision?.quality ?? 1) < 0.60)
    }

    @Test("Low-motion no-input oversize frame is admitted for quality recovery")
    func lowMotionNoInputOversizeFrameIsAdmittedForQualityRecovery() throws {
        var controller = HostAdaptivePFrameController()
        let recoveryAdmission = controller.evaluateEncodedFrame(
            byteCount: 55 * 1024,
            wireBytes: 55 * 1024,
            packetCount: packetCount(forWireBytes: 55 * 1024),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: false,
            sourceStill: false,
            currentBitrateBps: 12_000_000,
            requestedTargetBitrateBps: 300_000_000,
            startupCeilingBps: 300_000_000,
            minimumBitrateFloorBps: 2_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.20,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            latencyMode: .lowestLatency,
            now: 10
        )
        #expect(recoveryAdmission.admission == .send)
        #expect(recoveryAdmission.budgetDecision == nil)

        var inputController = HostAdaptivePFrameController()
        let inputAdmission = inputController.evaluateEncodedFrame(
            byteCount: 55 * 1024,
            wireBytes: 55 * 1024,
            packetCount: packetCount(forWireBytes: 55 * 1024),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: 12_000_000,
            requestedTargetBitrateBps: 300_000_000,
            startupCeilingBps: 300_000_000,
            minimumBitrateFloorBps: 2_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.20,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            latencyMode: .lowestLatency,
            now: 10
        )
        #expect(inputAdmission.admission == .sendWithQualityDrop)
        #expect(inputAdmission.budgetDecision?.reason == .encodedFrame)
    }

    @Test("Severe Most Responsive input oversize preserves the P-frame chain")
    func severeMostResponsiveInputOversizePreservesPFrameChain() {
        var controller = HostAdaptivePFrameController()
        let decision = controller.evaluateEncodedFrame(
            byteCount: 360 * 1024,
            wireBytes: 360 * 1024,
            packetCount: 308,
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 2_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            latencyMode: .lowestLatency,
            now: 10
        )

        #expect(decision.admission == .sendWithQualityDrop)
        #expect(decision.budgetDecision?.reason == .encodedFrame)
        #expect((decision.budgetDecision?.quality ?? 1) < 0.60)
    }

    @Test("All latency modes preserve the P-frame chain for the same oversize")
    func allLatencyModesPreservePFrameChainForSameOversize() {
        for mode in [MirageStreamLatencyMode.lowestLatency, .balanced, .smoothest] {
            var controller = HostAdaptivePFrameController()
            let decision = controller.evaluateEncodedFrame(
                byteCount: 360 * 1024,
                wireBytes: 360 * 1024,
                packetCount: 308,
                isKeyframe: false,
                receiverHealthy: true,
                senderHealthy: true,
                inputActive: true,
                sourceStill: false,
                currentBitrateBps: 60_000_000,
                requestedTargetBitrateBps: 60_000_000,
                startupCeilingBps: 60_000_000,
                minimumBitrateFloorBps: 2_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_200,
                currentQuality: 0.60,
                qualityFloor: 0.03,
                steadyQualityCeiling: 0.90,
                latencyMode: mode,
                now: 10
            )

            #expect(decision.admission == .sendWithQualityDrop)
        }
    }

    @Test("Catastrophic MB-scale oversize drops and targets a smaller repair keyframe")
    func catastrophicMBScaleOversizeDropsAndTargetsSmallerRepairKeyframe() throws {
        let operatingFrameBytes = 20 * 1024 * 1024
        let requestedFrameBytes = 80 * 1024 * 1024
        let oversizedFrameBytes = 60 * 1024 * 1024

        for mode in [MirageStreamLatencyMode.lowestLatency, .balanced, .smoothest] {
            var controller = HostAdaptivePFrameController()
            let decision = controller.evaluateEncodedFrame(
                byteCount: oversizedFrameBytes,
                wireBytes: oversizedFrameBytes,
                packetCount: packetCount(forWireBytes: oversizedFrameBytes),
                isKeyframe: false,
                receiverHealthy: true,
                senderHealthy: true,
                currentBitrateBps: bitrate(forFrameBytes: operatingFrameBytes),
                requestedTargetBitrateBps: bitrate(forFrameBytes: requestedFrameBytes),
                startupCeilingBps: bitrate(forFrameBytes: requestedFrameBytes),
                minimumBitrateFloorBps: 2_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_200,
                currentQuality: 0.60,
                qualityFloor: 0.03,
                steadyQualityCeiling: 0.90,
                latencyMode: mode,
                now: 10
            )
            let budget = try #require(decision.budgetDecision)

            #expect(decision.admission == .dropPFrameStartChainRepair)
            #expect(budget.reason == .adaptiveRepair)
            #expect(budget.maxWireBytes < oversizedFrameBytes)
            #expect(budget.maxWireBytes <= operatingFrameBytes)
            #expect(budget.keyframeQuality < 0.60)
            #expect(budget.keyframeQuality > 0.30)
        }
    }

    @Test("Stale samples and samples from old adaptive epochs are ignored")
    func staleSamplesAndOldEpochSamplesAreIgnored() {
        var staleController = HostAdaptivePFrameController()
        let staleDecision = recordDelivery(
            controller: &staleController,
            completionAgeAtFeedbackMs: 600,
            wireBytes: 128 * 1024,
            packetSpanMs: 90,
            completionGapMs: 90
        )
        #expect(staleDecision == nil)

        var epochController = HostAdaptivePFrameController()
        _ = epochController.recordFreshnessPressure(
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 2_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            latencyMode: .lowestLatency,
            now: 100
        )
        let oldEpochDecision = recordDelivery(
            controller: &epochController,
            frameNumber: 50,
            completionAgeAtFeedbackMs: 200,
            wireBytes: 128 * 1024,
            packetSpanMs: 8,
            completionGapMs: 8,
            now: 100.10
        )

        #expect(oldEpochDecision == nil)
    }

    @Test("Still frames ramp every clean delivery sample back toward ceiling")
    func stillFramesRampEveryCleanDeliverySampleBackTowardCeiling() throws {
        var controller = HostAdaptivePFrameController()
        let firstDecision = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: 24_000_000,
            requestedBitrate: 120_000_000,
            startupCeiling: 120_000_000,
            minimumFloor: 2_000_000,
            wireBytes: 80 * 1024,
            packetSpanMs: 5,
            completionGapMs: 5,
            currentQuality: 0.30
        ))
        let secondDecision = try #require(recordDelivery(
            controller: &controller,
            frameNumber: 2,
            currentBitrate: firstDecision.targetBitrateBps,
            requestedBitrate: 120_000_000,
            startupCeiling: 120_000_000,
            minimumFloor: 2_000_000,
            wireBytes: 80 * 1024,
            packetSpanMs: 5,
            completionGapMs: 5,
            currentQuality: firstDecision.quality
        ))

        #expect(firstDecision.reason == .healthy)
        #expect(secondDecision.reason == .healthy)
        #expect(secondDecision.maxWireBytes > firstDecision.maxWireBytes)
        #expect(secondDecision.quality > firstDecision.quality)
    }

    @Test("Still clean samples can probe past a recent motion pressure ceiling")
    func stillCleanSamplesCanProbePastRecentMotionPressureCeiling() throws {
        var controller = HostAdaptivePFrameController()
        let pressureDecision = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: 76_700_000,
            requestedBitrate: 180_000_000,
            startupCeiling: 180_000_000,
            minimumFloor: 3_000_000,
            inputActive: true,
            sourceStill: false,
            wireBytes: 48 * 1024,
            packetSpanMs: 42,
            completionGapMs: 42,
            currentQuality: 0.35,
            now: 10
        ))
        #expect(pressureDecision.reason == .pFrameLatency)

        var currentBitrate = pressureDecision.targetBitrateBps
        var currentQuality = pressureDecision.quality
        var latestBudget = pressureDecision.maxWireBytes
        var raiseCount = 0

        for frameNumber in 2...16 {
            guard let decision = recordDelivery(
                controller: &controller,
                frameNumber: UInt64(frameNumber),
                currentBitrate: currentBitrate,
                requestedBitrate: 180_000_000,
                startupCeiling: 180_000_000,
                minimumFloor: 3_000_000,
                inputActive: false,
                sourceStill: true,
                wireBytes: 12 * 1024,
                packetSpanMs: 4,
                completionGapMs: 4,
                currentQuality: currentQuality,
                now: 10.50 + Double(frameNumber) * 0.02
            ) else {
                continue
            }
            raiseCount += 1
            latestBudget = decision.maxWireBytes
            currentBitrate = decision.targetBitrateBps
            currentQuality = decision.quality
        }

        #expect(raiseCount > 0)
        #expect(latestBudget > pressureDecision.maxWireBytes)
        #expect(latestBudget > 64 * 1024)
    }

    @Test("Sparse source completion gaps with clean packet spans do not cut quality")
    func sparseSourceCompletionGapsWithCleanPacketSpansDoNotCutQuality() throws {
        var controller = HostAdaptivePFrameController()
        let decision = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: 24_000_000,
            requestedBitrate: 120_000_000,
            startupCeiling: 120_000_000,
            minimumFloor: 2_000_000,
            inputActive: false,
            sourceStill: true,
            wireBytes: 64 * 1024,
            packetSpanMs: 4,
            completionGapMs: 180,
            currentQuality: 0.20
        ))

        #expect(decision.reason == .healthy)
        #expect(decision.state == .observing)
        #expect(decision.maxWireBytes > frameBytes(for: 24_000_000))
        #expect(decision.quality > 0.20)
    }

    @Test("Tiny sparse frame completion gaps do not poison capacity")
    func tinySparseFrameCompletionGapsDoNotPoisonCapacity() throws {
        var controller = HostAdaptivePFrameController()
        let seededDecision = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: 4_800_000,
            requestedBitrate: 76_000_000,
            startupCeiling: 180_000_000,
            minimumFloor: 4_800_000,
            wireBytes: 20 * 1024,
            packetSpanMs: 1,
            completionGapMs: 1,
            currentQuality: 0.10
        ))
        let sparseDecision = try #require(recordDelivery(
            controller: &controller,
            frameNumber: 2,
            currentBitrate: seededDecision.targetBitrateBps,
            requestedBitrate: 76_000_000,
            startupCeiling: 180_000_000,
            minimumFloor: 4_800_000,
            wireBytes: 512,
            packetSpanMs: 1,
            completionGapMs: 250,
            currentQuality: seededDecision.quality,
            now: 10.05
        ))

        #expect(sparseDecision.reason == .healthy)
        #expect(sparseDecision.maxWireBytes > seededDecision.maxWireBytes)

        let admission = controller.evaluateEncodedFrame(
            byteCount: 512,
            wireBytes: 512,
            packetCount: 1,
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            currentBitrateBps: sparseDecision.targetBitrateBps,
            requestedTargetBitrateBps: 76_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 4_800_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: sparseDecision.quality,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            latencyMode: .lowestLatency,
            now: 10.10
        )

        #expect(admission.admission == .send)
        #expect(admission.budgetDecision == nil)
    }

    @Test("Near-floor P-frame oversize sends without resetting quality")
    func nearFloorPFrameOversizeSendsWithoutResettingQuality() {
        var controller = HostAdaptivePFrameController()
        let admission = controller.evaluateEncodedFrame(
            byteCount: 16 * 1024,
            wireBytes: 16 * 1024,
            packetCount: 14,
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            currentBitrateBps: 4_800_000,
            requestedTargetBitrateBps: 76_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 4_800_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.06,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            latencyMode: .lowestLatency,
            now: 10
        )

        #expect(admission.admission == .send)
        #expect(admission.budgetDecision == nil)
    }

    @Test("Near-floor completion gaps do not force latency cuts")
    func nearFloorCompletionGapsDoNotForceLatencyCuts() {
        var controller = HostAdaptivePFrameController()
        let decision = recordDelivery(
            controller: &controller,
            currentBitrate: 4_800_000,
            requestedBitrate: 76_000_000,
            startupCeiling: 180_000_000,
            minimumFloor: 4_800_000,
            wireBytes: 16 * 1024,
            packetSpanMs: 12,
            completionGapMs: 120,
            currentQuality: 0.06
        )

        if let decision {
            #expect(decision.reason != .pFrameLatency)
        }
    }

    @Test("Backlog-only feedback and startup recovery do not cut frame budget")
    func backlogOnlyFeedbackAndStartupRecoveryDoNotCutFrameBudget() {
        var controller = HostAdaptivePFrameController()
        let backlogDecision = controller.update(
            with: receiverFeedback(sequence: 1, reassemblyBacklogFrames: 1, reassemblyBacklogBytes: 16 * 1024),
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 2_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            now: 10
        )
        let startupRecoveryDecision = controller.update(
            with: receiverFeedback(sequence: 2, recoveryState: .startup),
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 2_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            now: 10.1
        )
        let keyframeRecoveryDecision = controller.update(
            with: receiverFeedback(sequence: 3, recoveryState: .keyframeRecovery),
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 2_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            now: 10.2
        )

        #expect(backlogDecision == nil)
        #expect(startupRecoveryDecision == nil)
        #expect(keyframeRecoveryDecision?.reason == .clientRecovery)
    }

    @Test("Allowed P-frame spike helpers stay monotonic")
    func allowedPFrameSpikeHelpersStayMonotonic() {
        #expect(HostAdaptivePFrameController.allowedPFrameSpikeRatio(baselineWireBytes: 13 * 1024) > 3.0)
        #expect(HostAdaptivePFrameController.allowedPFrameSpikeRatio(baselineWireBytes: 2 * 1024 * 1024) == 1.25)
        #expect(HostAdaptivePFrameController.allowedPFrameSpikePacketCount(
            baselinePacketCount: 10,
            allowedSpikeRatio: 2.0
        ) == 20)
    }
}

private func recordDelivery(
    controller: inout HostAdaptivePFrameController,
    frameNumber: UInt64 = 1,
    currentBitrate: Int = 60_000_000,
    requestedBitrate: Int = 60_000_000,
    startupCeiling: Int = 60_000_000,
    minimumFloor: Int = 2_000_000,
    inputActive: Bool = true,
    sourceStill: Bool = false,
    capacityLearningAllowed: Bool = true,
    completionAgeAtFeedbackMs: Double = 0,
    wireBytes: Int,
    packetSpanMs: Double,
    completionGapMs: Double,
    currentQuality: Float = 0.60,
    latencyMode: MirageStreamLatencyMode = .lowestLatency,
    now: CFAbsoluteTime = 10
) -> HostFrameBudgetDecision? {
    controller.recordFrameTransportCompletion(
        frameNumber: frameNumber,
        wireBytes: wireBytes,
        packetCount: Int((Double(wireBytes) / 1_200.0).rounded(.up)),
        isKeyframe: false,
        sendCompletionMs: packetSpanMs,
        packetSpanMs: packetSpanMs,
        completionGapMs: completionGapMs,
        completionAgeAtFeedbackMs: completionAgeAtFeedbackMs,
        firstPacketGapMs: completionGapMs,
        timingSource: .clientAssembled,
        receiverHealthy: true,
        capacityLearningAllowed: capacityLearningAllowed,
        inputActive: inputActive,
        sourceStill: sourceStill,
        currentBitrateBps: currentBitrate,
        requestedTargetBitrateBps: requestedBitrate,
        startupCeilingBps: startupCeiling,
        minimumBitrateFloorBps: minimumFloor,
        currentFrameRate: 60,
        maxPayloadSize: 1_200,
        currentQuality: currentQuality,
        qualityFloor: 0.03,
        steadyQualityCeiling: 0.90,
        latencyMode: latencyMode,
        now: now
    )
}

private func frameBytes(for bitrate: Int, frameRate: Int = 60) -> Int {
    Int((Double(bitrate) / 8.0 / Double(frameRate)).rounded(.up))
}

private func bitrate(forFrameBytes bytes: Int, frameRate: Int = 60) -> Int {
    max(1, bytes * 8 * frameRate)
}

private func packetCount(forWireBytes bytes: Int, maxPayloadSize: Int = 1_200) -> Int {
    Int((Double(bytes) / Double(maxPayloadSize)).rounded(.up))
}

private func receiverFeedback(
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
        pFrameTimingSamples: [],
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
#endif
