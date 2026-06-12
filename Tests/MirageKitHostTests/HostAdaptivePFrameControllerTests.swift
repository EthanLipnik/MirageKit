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

    @Test("Non-AWDL startup probe budget does not shrink at 120Hz")
    func nonAwdlStartupProbeBudgetDoesNotShrinkAt120Hz() throws {
        var sixtyController = HostAdaptivePFrameController()
        var highRefreshController = HostAdaptivePFrameController()
        let requestedBitrate = 76_700_000

        let sixty = try #require(recordDelivery(
            controller: &sixtyController,
            currentBitrate: requestedBitrate,
            requestedBitrate: requestedBitrate,
            startupCeiling: 180_000_000,
            minimumFloor: 3_000_000,
            wireBytes: 20 * 1024,
            packetSpanMs: 3,
            completionGapMs: 3,
            currentQuality: 0.40,
            currentFrameRate: 60
        ))
        let highRefresh = try #require(recordDelivery(
            controller: &highRefreshController,
            currentBitrate: requestedBitrate,
            requestedBitrate: requestedBitrate,
            startupCeiling: 180_000_000,
            minimumFloor: 3_000_000,
            wireBytes: 20 * 1024,
            packetSpanMs: 3,
            completionGapMs: 3,
            currentQuality: 0.40,
            currentFrameRate: 120
        ))

        #expect(highRefresh.maxWireBytes == sixty.maxWireBytes)
    }

    @Test("One stale receiver delivery sample cuts immediately")
    func oneStaleReceiverDeliverySampleCutsImmediately() throws {
        var controller = HostAdaptivePFrameController()

        let decision = try #require(recordDelivery(
            controller: &controller,
            wireBytes: 240 * 1024,
            packetSpanMs: 700,
            completionGapMs: 700
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
            packetSpanMs: 700,
            completionGapMs: 700
        ))

        #expect(decision.reason == .pFrameLatency)
        #expect(decision.state == .severe)
        #expect(decision.maxWireBytes < frameBytes(for: 60_000_000))
    }

    @Test("AWDL timing pressure records structural pressure before cutting quality")
    func awdlTimingPressureRecordsStructuralPressureBeforeCuttingQuality() throws {
        var controller = HostAdaptivePFrameController()

        let decision = recordDelivery(
            controller: &controller,
            wireBytes: 160 * 1024,
            packetSpanMs: 120,
            completionGapMs: 120,
            mediaPathProfile: .awdlRadio,
            receiverPlayoutDelayTargetMs: 80,
            awdlQualityReductionAllowed: false
        )

        #expect(decision == nil)
        #expect(controller.latestReason == .startup)
        let signal = try #require(controller.latestQualityGatedPFramePressure)
        #expect(signal.reason == .pFrameLatency)
        #expect(signal.deliveryMs == 120)
        #expect(signal.targetClearMs == 80)
    }

    @Test("AWDL survival permits P-frame timing quality cuts")
    func awdlSurvivalPermitsPFrameTimingQualityCuts() throws {
        var controller = HostAdaptivePFrameController()

        let decision = try #require(recordDelivery(
            controller: &controller,
            wireBytes: 160 * 1024,
            packetSpanMs: 120,
            completionGapMs: 120,
            mediaPathProfile: .awdlRadio,
            receiverPlayoutDelayTargetMs: 80,
            awdlQualityReductionAllowed: true
        ))

        #expect(decision.reason == .pFrameLatency)
        #expect(decision.state == .pressured)
    }

    @Test("AWDL receiver completion gap records structural pressure with clean packet span")
    func awdlReceiverCompletionGapRecordsStructuralPressureWithCleanPacketSpan() throws {
        var controller = HostAdaptivePFrameController()

        let decision = recordDelivery(
            controller: &controller,
            wireBytes: 160 * 1024,
            packetSpanMs: 12,
            completionGapMs: 120,
            mediaPathProfile: .awdlRadio,
            receiverPlayoutDelayTargetMs: 80,
            awdlQualityReductionAllowed: false
        )

        #expect(decision == nil)
        let signal = try #require(controller.latestQualityGatedPFramePressure)
        #expect(signal.reason == .pFrameLatency)
        #expect(signal.packetSpanMs == 12)
        #expect(signal.completionGapMs == 120)
        #expect(signal.deliveryMs == 120)
    }

    @Test("AWDL survival uses receiver completion gap for P-frame timing cuts")
    func awdlSurvivalUsesReceiverCompletionGapForPFrameTimingCuts() throws {
        var controller = HostAdaptivePFrameController()

        let decision = try #require(recordDelivery(
            controller: &controller,
            wireBytes: 160 * 1024,
            packetSpanMs: 12,
            completionGapMs: 120,
            mediaPathProfile: .awdlRadio,
            receiverPlayoutDelayTargetMs: 80,
            awdlQualityReductionAllowed: true
        ))

        #expect(decision.reason == .pFrameLatency)
        #expect(decision.state == .pressured)
        #expect(decision.quality < 0.60)
    }

    @Test("Non-AWDL receiver completion gap cuts when motion growth has clean packet span")
    func nonAwdlReceiverCompletionGapCutsWhenMotionGrowthHasCleanPacketSpan() throws {
        var controller = HostAdaptivePFrameController()
        let currentBitrate = 221_500_000

        _ = recordDelivery(
            controller: &controller,
            currentBitrate: currentBitrate,
            requestedBitrate: currentBitrate,
            startupCeiling: currentBitrate,
            minimumFloor: 4_800_000,
            inputActive: true,
            sourceStill: false,
            wireBytes: 31 * 1024,
            packetSpanMs: 4,
            completionGapMs: 4,
            currentQuality: 0.75,
            mediaPathProfile: .localWiFi
        )
        let decision = try #require(recordDelivery(
            controller: &controller,
            frameNumber: 2,
            currentBitrate: currentBitrate,
            requestedBitrate: currentBitrate,
            startupCeiling: currentBitrate,
            minimumFloor: 4_800_000,
            inputActive: true,
            sourceStill: false,
            wireBytes: 88 * 1024,
            packetSpanMs: 4,
            completionGapMs: 220,
            currentQuality: 0.75,
            mediaPathProfile: .localWiFi,
            now: 10.02
        ))

        #expect(decision.reason == .pFrameLatency)
        #expect(decision.state == .severe)
        #expect(decision.targetBitrateBps < currentBitrate)
        #expect(decision.quality < 0.75)
        #expect(decision.maxWireBytes < frameBytes(for: currentBitrate))
    }

    @Test("AWDL encoded oversize sends before quality reduction is allowed")
    func awdlEncodedOversizeSendsBeforeQualityReductionIsAllowed() {
        var controller = HostAdaptivePFrameController()
        let decision = controller.evaluateEncodedFrame(
            byteCount: 360 * 1024,
            wireBytes: 360 * 1024,
            packetCount: packetCount(forWireBytes: 360 * 1024),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 18_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.12,
            steadyQualityCeiling: 0.90,
            latencyMode: .balanced,
            mediaPathProfile: .awdlRadio,
            receiverPlayoutDelayTargetMs: 80,
            awdlQualityReductionAllowed: false,
            now: 10
        )

        #expect(decision.admission == .send)
        #expect(decision.budgetDecision == nil)
    }

    @Test("AWDL frame budget clamps high encoder readability hint to transport ceiling")
    func awdlFrameBudgetClampsHighEncoderReadabilityHintToTransportCeiling() {
        var controller = HostAdaptivePFrameController()
        let decision = controller.evaluateEncodedFrame(
            byteCount: 120 * 1024,
            wireBytes: 120 * 1024,
            packetCount: packetCount(forWireBytes: 120 * 1024),
            isKeyframe: false,
            receiverHealthy: false,
            senderHealthy: false,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: 72_000_000,
            requestedTargetBitrateBps: 220_000_000,
            startupCeilingBps: 32_000_000,
            minimumBitrateFloorBps: 18_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.32,
            qualityFloor: 0.16,
            steadyQualityCeiling: 0.42,
            latencyMode: .balanced,
            mediaPathProfile: .awdlRadio,
            receiverPlayoutDelayTargetMs: 80,
            awdlQualityReductionAllowed: false,
            now: 10
        )

        #expect(decision.byteRatio > 1.5)
        #expect(decision.budgetDecision == nil)
    }

    @Test("AWDL catastrophic oversize repairs chain without budget cut before quality reduction is allowed")
    func awdlCatastrophicOversizeRepairsChainWithoutBudgetCutBeforeQualityReductionIsAllowed() {
        var controller = HostAdaptivePFrameController()
        let operatingFrameBytes = 4 * 1024 * 1024
        let requestedFrameBytes = 16 * 1024 * 1024
        let oversizedFrameBytes = 12 * 1024 * 1024

        let decision = controller.evaluateEncodedFrame(
            byteCount: oversizedFrameBytes,
            wireBytes: oversizedFrameBytes,
            packetCount: packetCount(forWireBytes: oversizedFrameBytes),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: bitrate(forFrameBytes: operatingFrameBytes),
            requestedTargetBitrateBps: bitrate(forFrameBytes: requestedFrameBytes),
            startupCeilingBps: bitrate(forFrameBytes: requestedFrameBytes),
            minimumBitrateFloorBps: 18_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.12,
            steadyQualityCeiling: 0.90,
            latencyMode: .balanced,
            mediaPathProfile: .awdlRadio,
            receiverPlayoutDelayTargetMs: 80,
            awdlQualityReductionAllowed: false,
            now: 10
        )

        #expect(decision.admission == .dropPFrameStartChainRepair)
        #expect(decision.budgetDecision == nil)
    }

    @Test("AWDL catastrophic oversize can cut budget once quality reduction is allowed")
    func awdlCatastrophicOversizeCanCutBudgetOnceQualityReductionIsAllowed() throws {
        var controller = HostAdaptivePFrameController()
        let operatingFrameBytes = 4 * 1024 * 1024
        let requestedFrameBytes = 16 * 1024 * 1024
        let oversizedFrameBytes = 12 * 1024 * 1024

        let decision = controller.evaluateEncodedFrame(
            byteCount: oversizedFrameBytes,
            wireBytes: oversizedFrameBytes,
            packetCount: packetCount(forWireBytes: oversizedFrameBytes),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: bitrate(forFrameBytes: operatingFrameBytes),
            requestedTargetBitrateBps: bitrate(forFrameBytes: requestedFrameBytes),
            startupCeilingBps: bitrate(forFrameBytes: requestedFrameBytes),
            minimumBitrateFloorBps: 18_000_000,
            currentFrameRate: 30,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.12,
            steadyQualityCeiling: 0.90,
            latencyMode: .balanced,
            mediaPathProfile: .awdlRadio,
            receiverPlayoutDelayTargetMs: 120,
            awdlQualityReductionAllowed: true,
            now: 10
        )
        let budget = try #require(decision.budgetDecision)

        #expect(decision.admission == .dropPFrameStartChainRepair)
        #expect(budget.reason == .adaptiveRepair)
        #expect(budget.maxWireBytes < oversizedFrameBytes)
        #expect(budget.quality < 0.60)
        #expect(budget.quality >= 0.12)
    }

    @Test("Frame-rate retune preserves AWDL per-frame bitrate budget")
    func frameRateRetunePreservesAwdlPerFrameBitrateBudget() throws {
        var controller = HostAdaptivePFrameController()

        _ = controller.evaluateEncodedFrame(
            byteCount: 40 * 1024,
            wireBytes: 40 * 1024,
            packetCount: packetCount(forWireBytes: 40 * 1024),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 18_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.12,
            steadyQualityCeiling: 0.90,
            latencyMode: .balanced,
            mediaPathProfile: .awdlRadio,
            receiverPlayoutDelayTargetMs: 80,
            awdlQualityReductionAllowed: false,
            now: 10
        )
        let initialBudget = try #require(controller.operatingTargetWireBytes)

        controller.retuneForFrameRateChange(
            from: 60,
            to: 30,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 18_000_000,
            maxPayloadSize: 1_200,
            mediaPathProfile: .awdlRadio
        )
        let demotedBudget = try #require(controller.operatingTargetWireBytes)

        #expect(demotedBudget == initialBudget)
        #expect(controller.runtimeCeilingBps == 30_000_000)

        controller.retuneForFrameRateChange(
            from: 30,
            to: 60,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 18_000_000,
            maxPayloadSize: 1_200,
            mediaPathProfile: .awdlRadio
        )

        #expect(controller.operatingTargetWireBytes == initialBudget)
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
            packetSpanMs: 700,
            completionGapMs: 700
        ))

        #expect(decision.maxWireBytes < oldThirtyFivePercentFloorBytes)
        #expect(decision.maxWireBytes >= frameBytes(for: 2_000_000))
    }

    @Test("Fresh input oversize sends when it fits motion target")
    func freshInputOversizeSendsWhenItFitsMotionTarget() throws {
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

        #expect(decision.admission == .send)
        #expect(decision.budgetDecision == nil)
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
            deliveryMode: .lowMotionRamp,
            now: 10
        )
        let recoveryBudget = try #require(recoveryAdmission.budgetDecision)
        #expect(recoveryAdmission.admission == .send)
        #expect(recoveryAdmission.deliveryMode == .lowMotionRamp)
        #expect(recoveryBudget.reason == .healthy)
        #expect(recoveryBudget.quality == 0.20)
        #expect(recoveryBudget.targetBitrateBps > 12_000_000)

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
        let inputBudget = try #require(inputAdmission.budgetDecision)
        #expect(inputAdmission.admission == .sendWithQualityDrop)
        #expect(inputAdmission.deliveryMode == .realtime)
        #expect(inputBudget.reason == .encodedFrame)
    }

    @Test("Large local input oversize drops before it stalls transport")
    func largeLocalInputOversizeDropsBeforeItStallsTransport() throws {
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
            mediaPathProfile: .localWiFi,
            now: 10
        )
        let budget = try #require(decision.budgetDecision)

        #expect(decision.admission == .dropPFrameStartChainRepair)
        #expect(budget.reason == .encodedFrame)
        #expect(budget.quality < 0.60)
    }

    @Test("Input oversize within motion target sends before transport")
    func inputOversizeWithinMotionTargetSendsBeforeTransport() throws {
        var controller = HostAdaptivePFrameController()
        let decision = controller.evaluateEncodedFrame(
            byteCount: 180 * 1024,
            wireBytes: 180 * 1024,
            packetCount: packetCount(forWireBytes: 180 * 1024),
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

        #expect(decision.admission == .send)
        #expect(decision.budgetDecision == nil)
    }

    @Test("Sudden motion growth below bitrate target lowers quality before transport")
    func suddenMotionGrowthBelowBitrateTargetLowersQualityBeforeTransport() throws {
        var controller = HostAdaptivePFrameController()
        let currentBitrate = 221_500_000
        let baselineBytes = 64 * 1024
        let spikeBytes = 140 * 1024
        #expect(spikeBytes < frameBytes(for: currentBitrate))

        let first = controller.evaluateEncodedFrame(
            byteCount: baselineBytes,
            wireBytes: baselineBytes,
            packetCount: packetCount(forWireBytes: baselineBytes),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: false,
            sourceStill: false,
            currentBitrateBps: currentBitrate,
            requestedTargetBitrateBps: currentBitrate,
            startupCeilingBps: currentBitrate,
            minimumBitrateFloorBps: 4_800_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.75,
            qualityFloor: 0.04,
            steadyQualityCeiling: 0.94,
            latencyMode: .lowestLatency,
            now: 10
        )
        let second = controller.evaluateEncodedFrame(
            byteCount: spikeBytes,
            wireBytes: spikeBytes,
            packetCount: packetCount(forWireBytes: spikeBytes),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: false,
            sourceStill: false,
            currentBitrateBps: currentBitrate,
            requestedTargetBitrateBps: currentBitrate,
            startupCeilingBps: currentBitrate,
            minimumBitrateFloorBps: 4_800_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.75,
            qualityFloor: 0.04,
            steadyQualityCeiling: 0.94,
            latencyMode: .lowestLatency,
            now: 10.02
        )
        let budget = try #require(second.budgetDecision)

        #expect(first.admission == .send)
        #expect(first.budgetDecision == nil)
        #expect(second.admission == .sendWithQualityDrop)
        #expect(budget.reason == .encodedFrame)
        #expect(budget.targetBitrateBps < currentBitrate)
        #expect(budget.quality < 0.75)
        #expect(budget.maxWireBytes < frameBytes(for: currentBitrate))
    }

    @Test("Small clean spike below active budget does not lower quality before transport")
    func smallCleanSpikeBelowActiveBudgetDoesNotLowerQualityBeforeTransport() {
        var controller = HostAdaptivePFrameController()
        let currentBitrate = 60_000_000
        let baselineBytes = 11 * 1024
        let spikeBytes = 42 * 1024
        #expect(spikeBytes < frameBytes(for: currentBitrate))

        let first = controller.evaluateEncodedFrame(
            byteCount: baselineBytes,
            wireBytes: baselineBytes,
            packetCount: packetCount(forWireBytes: baselineBytes),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: false,
            sourceStill: false,
            currentBitrateBps: currentBitrate,
            requestedTargetBitrateBps: currentBitrate,
            startupCeilingBps: currentBitrate,
            minimumBitrateFloorBps: 4_800_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.04,
            steadyQualityCeiling: 0.94,
            latencyMode: .lowestLatency,
            now: 10
        )
        let second = controller.evaluateEncodedFrame(
            byteCount: spikeBytes,
            wireBytes: spikeBytes,
            packetCount: packetCount(forWireBytes: spikeBytes),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: false,
            sourceStill: false,
            currentBitrateBps: currentBitrate,
            requestedTargetBitrateBps: currentBitrate,
            startupCeilingBps: currentBitrate,
            minimumBitrateFloorBps: 4_800_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.60,
            qualityFloor: 0.04,
            steadyQualityCeiling: 0.94,
            latencyMode: .lowestLatency,
            now: 10.02
        )

        #expect(first.admission == .send)
        #expect(first.budgetDecision == nil)
        #expect(second.admission == .send)
        #expect(second.budgetDecision == nil)
    }

    @Test("All latency modes admit fresh oversize frames that fit motion target")
    func allLatencyModesAdmitFreshOversizeFramesThatFitMotionTarget() {
        for mode in [MirageStreamLatencyMode.lowestLatency, .balanced, .smoothest] {
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
                latencyMode: mode,
                now: 10
            )

            #expect(decision.admission == .send)
            #expect(decision.budgetDecision == nil)
        }
    }

    @Test("Regular VPN readable encoded frames keep existing deadline behavior")
    func regularVPNReadableEncodedFramesKeepExistingDeadlineBehavior() throws {
        let mildlyLateBytes = 100 * 1024
        let frameInterval = 1.0 / 60.0

        var controller = HostAdaptivePFrameController()
        let decision = controller.evaluateEncodedFrame(
            byteCount: mildlyLateBytes,
            wireBytes: mildlyLateBytes,
            packetCount: packetCount(forWireBytes: mildlyLateBytes),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: 2_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 60_000_000,
            minimumBitrateFloorBps: 2_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.70,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            latencyMode: .lowestLatency,
            mediaPathProfile: .vpnOrOverlay,
            now: 10
        )
        let budget = try #require(decision.budgetDecision)

        #expect(decision.admission == .sendWithQualityDrop)
        #expect(budget.reason == .encodedFrame)
        #expect(abs(decision.sendDeadline - (10 + frameInterval)) < 0.0001)
    }

    @Test("Optimized VPN readable encoded frames get extended deadline slack")
    func optimizedVPNReadableEncodedFramesGetExtendedDeadlineSlack() {
        let mildlyLateBytes = 100 * 1024
        let frameInterval = 1.0 / 30.0

        var readableQualityController = HostAdaptivePFrameController()
        let readableQualityDecision = readableQualityController.evaluateEncodedFrame(
            byteCount: mildlyLateBytes,
            wireBytes: mildlyLateBytes,
            packetCount: packetCount(forWireBytes: mildlyLateBytes),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: 22_000_000,
            requestedTargetBitrateBps: 36_000_000,
            startupCeilingBps: 76_000_000,
            minimumBitrateFloorBps: 22_000_000,
            currentFrameRate: 30,
            maxPayloadSize: 1_200,
            currentQuality: 0.70,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            latencyMode: .lowestLatency,
            mediaPathProfile: .vpnOrOverlay,
            now: 10
        )

        #expect(readableQualityDecision.admission == .send)
        #expect(readableQualityDecision.budgetDecision == nil)
        #expect(readableQualityDecision.sendDeadline > 10 + frameInterval)
        #expect(readableQualityDecision.sendDeadline <= 10 + 0.080)

        var lowQualityController = HostAdaptivePFrameController()
        let lowQualityDecision = lowQualityController.evaluateEncodedFrame(
            byteCount: mildlyLateBytes,
            wireBytes: mildlyLateBytes,
            packetCount: packetCount(forWireBytes: mildlyLateBytes),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: 22_000_000,
            requestedTargetBitrateBps: 36_000_000,
            startupCeilingBps: 76_000_000,
            minimumBitrateFloorBps: 22_000_000,
            currentFrameRate: 30,
            maxPayloadSize: 1_200,
            currentQuality: 0.55,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            latencyMode: .lowestLatency,
            mediaPathProfile: .vpnOrOverlay,
            now: 10
        )

        #expect(lowQualityDecision.admission == .send)
        #expect(lowQualityDecision.budgetDecision == nil)
        #expect(lowQualityDecision.sendDeadline > 10 + frameInterval)
        #expect(lowQualityDecision.sendDeadline <= 10 + 0.080)
    }

    @Test("VPN sender deadline pressure keeps runtime quality ceiling readable")
    func vpnSenderDeadlinePressureKeepsRuntimeQualityCeilingReadable() throws {
        var controller = HostAdaptivePFrameController()

        let maybeDecision = controller.recordSenderDeadlineDrop(
            currentBitrateBps: 36_000_000,
            requestedTargetBitrateBps: 36_000_000,
            startupCeilingBps: 76_000_000,
            minimumBitrateFloorBps: 22_000_000,
            currentFrameRate: 30,
            maxPayloadSize: 1_200,
            currentQuality: 0.70,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.80,
            latencyMode: .lowestLatency,
            mediaPathProfile: .vpnOrOverlay,
            now: 10
        )
        let decision = try #require(maybeDecision)

        #expect(decision.reason == .senderDeadline)
        #expect(decision.qualityCeiling >= 0.50)
        #expect(decision.qualityCeiling <= 0.80)
    }

    @Test("VPN low-readability timing slack still cuts severe pressure")
    func vpnLowReadabilityTimingSlackStillCutsSeverePressure() throws {
        var controller = HostAdaptivePFrameController()

        let decision = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: 2_000_000,
            requestedBitrate: 60_000_000,
            startupCeiling: 60_000_000,
            minimumFloor: 2_000_000,
            inputActive: true,
            sourceStill: false,
            wireBytes: 160 * 1024,
            packetSpanMs: 700,
            completionGapMs: 700,
            currentQuality: 0.50,
            mediaPathProfile: .vpnOrOverlay
        ))

        #expect(decision.reason == .pFrameLatency)
        #expect(decision.state == .pressured || decision.state == .severe)
        #expect(decision.quality < 0.50)
    }

    @Test("Low-readability timing slack is scoped to VPN")
    func lowReadabilityTimingSlackIsScopedToVPN() throws {
        var controller = HostAdaptivePFrameController()

        let decision = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: 2_000_000,
            requestedBitrate: 60_000_000,
            startupCeiling: 60_000_000,
            minimumFloor: 2_000_000,
            inputActive: true,
            sourceStill: false,
            wireBytes: 100 * 1024,
            packetSpanMs: 400,
            completionGapMs: 400,
            currentQuality: 0.55,
            mediaPathProfile: .localWiFi
        ))

        #expect(decision.reason == .pFrameLatency)
    }

    @Test("Catastrophic MB-scale over-headroom frame drops and targets a smaller repair keyframe")
    func catastrophicMBScaleOverHeadroomFrameDropsAndTargetsSmallerRepairKeyframe() throws {
        let operatingFrameBytes = 20 * 1024 * 1024
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

    @Test("Report-sized low-motion P-frame recommends bitrate raise before quality-only ramp")
    func reportSizedLowMotionPFrameRecommendsBitrateRaiseBeforeQualityOnlyRamp() throws {
        var controller = HostAdaptivePFrameController()

        let decision = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: 36_000_000,
            requestedBitrate: 36_000_000,
            startupCeiling: 75_500_000,
            minimumFloor: 12_000_000,
            inputActive: false,
            sourceStill: false,
            deliveryMode: .lowMotionRamp,
            wireBytes: 170_533,
            packetSpanMs: 34.5,
            completionGapMs: 34.5,
            currentQuality: 0.80,
            mediaPathProfile: .vpnOrOverlay,
            currentFrameRate: 30
        ))

        #expect(decision.reason == .healthy)
        #expect(decision.targetBitrateBps > 36_000_000)
        #expect(decision.targetBitrateBps >= 50_000_000)
        #expect(decision.quality == 0.80)
        #expect(controller.latestDeliveryMode == .lowMotionRamp)
        #expect((controller.latestRequiredBitrateForCurrentQualityBps ?? 0) > 36_000_000)
        #expect(controller.latestObservedPFrameWireBytesP95 == 170_533)
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
            packetSpanMs: 420,
            completionGapMs: 420,
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

    @Test("Recent passive motion pressure rate limits healthy raise bursts")
    func recentPassiveMotionPressureRateLimitsHealthyRaiseBursts() throws {
        var controller = HostAdaptivePFrameController()
        let pressureDecision = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: 180_000_000,
            requestedBitrate: 180_000_000,
            startupCeiling: 180_000_000,
            minimumFloor: 3_000_000,
            inputActive: false,
            sourceStill: false,
            wireBytes: 160 * 1024,
            packetSpanMs: 420,
            completionGapMs: 420,
            currentQuality: 0.75,
            now: 10
        ))
        #expect(pressureDecision.reason == .pFrameLatency)

        let firstRaise = try #require(recordDelivery(
            controller: &controller,
            frameNumber: 2,
            currentBitrate: pressureDecision.targetBitrateBps,
            requestedBitrate: 180_000_000,
            startupCeiling: 180_000_000,
            minimumFloor: 3_000_000,
            inputActive: false,
            sourceStill: false,
            wireBytes: 160 * 1024,
            packetSpanMs: 4,
            completionGapMs: 4,
            currentQuality: pressureDecision.quality,
            now: 10.12
        ))
        let suppressedRaise = recordDelivery(
            controller: &controller,
            frameNumber: 3,
            currentBitrate: firstRaise.targetBitrateBps,
            requestedBitrate: 180_000_000,
            startupCeiling: 180_000_000,
            minimumFloor: 3_000_000,
            inputActive: false,
            sourceStill: false,
            wireBytes: 160 * 1024,
            packetSpanMs: 4,
            completionGapMs: 4,
            currentQuality: firstRaise.quality,
            now: 10.14
        )
        let laterRaise = try #require(recordDelivery(
            controller: &controller,
            frameNumber: 4,
            currentBitrate: firstRaise.targetBitrateBps,
            requestedBitrate: 180_000_000,
            startupCeiling: 180_000_000,
            minimumFloor: 3_000_000,
            inputActive: false,
            sourceStill: false,
            wireBytes: 160 * 1024,
            packetSpanMs: 4,
            completionGapMs: 4,
            currentQuality: firstRaise.quality,
            now: 10.34
        ))

        #expect(firstRaise.reason == .healthy)
        #expect(suppressedRaise == nil)
        #expect(laterRaise.reason == .healthy)
        #expect(laterRaise.maxWireBytes > firstRaise.maxWireBytes)
    }

    @Test("Clean samples at bitrate ceiling still raise quality")
    func cleanSamplesAtBitrateCeilingStillRaiseQuality() throws {
        var controller = HostAdaptivePFrameController()
        _ = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: 76_700_000,
            requestedBitrate: 180_000_000,
            startupCeiling: 180_000_000,
            minimumFloor: 3_000_000,
            inputActive: true,
            sourceStill: false,
            wireBytes: 20 * 1024,
            packetSpanMs: 4,
            completionGapMs: 4,
            currentQuality: 0.35,
            now: 10
        ))
        controller.retuneForBitrateChange(
            currentBitrateBps: 180_000_000,
            requestedTargetBitrateBps: 180_000_000,
            startupCeilingBps: 180_000_000,
            minimumBitrateFloorBps: 3_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            mediaPathProfile: .localWiFi,
            allowsBudgetRaise: true
        )

        let decision = try #require(recordDelivery(
            controller: &controller,
            frameNumber: 2,
            currentBitrate: 180_000_000,
            requestedBitrate: 180_000_000,
            startupCeiling: 180_000_000,
            minimumFloor: 3_000_000,
            inputActive: true,
            sourceStill: false,
            wireBytes: 160 * 1024,
            packetSpanMs: 4,
            completionGapMs: 4,
            currentQuality: 0.35,
            now: 10.40
        ))

        #expect(decision.reason == .healthy)
        #expect(decision.targetBitrateBps == 180_000_000)
        #expect(decision.maxWireBytes == frameBytes(for: 180_000_000))
        #expect(decision.quality > 0.35)
        #expect(decision.quality < 0.45)
    }

    @Test("Encoded-frame pressure does not update clean P-frame baseline")
    func encodedFramePressureDoesNotUpdateCleanPFrameBaseline() throws {
        var controller = HostAdaptivePFrameController()
        let currentBitrate = 221_500_000
        let baselineBytes = 64 * 1024
        let spikeBytes = 140 * 1024

        _ = controller.evaluateEncodedFrame(
            byteCount: baselineBytes,
            wireBytes: baselineBytes,
            packetCount: packetCount(forWireBytes: baselineBytes),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: false,
            sourceStill: false,
            currentBitrateBps: currentBitrate,
            requestedTargetBitrateBps: currentBitrate,
            startupCeilingBps: currentBitrate,
            minimumBitrateFloorBps: 4_800_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.75,
            qualityFloor: 0.04,
            steadyQualityCeiling: 0.94,
            latencyMode: .lowestLatency,
            now: 10
        )
        let cleanBaseline = try #require(controller.recentCleanPFrameBaselineWireBytes)

        let pressure = controller.evaluateEncodedFrame(
            byteCount: spikeBytes,
            wireBytes: spikeBytes,
            packetCount: packetCount(forWireBytes: spikeBytes),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: false,
            sourceStill: false,
            currentBitrateBps: currentBitrate,
            requestedTargetBitrateBps: currentBitrate,
            startupCeilingBps: currentBitrate,
            minimumBitrateFloorBps: 4_800_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: 0.75,
            qualityFloor: 0.04,
            steadyQualityCeiling: 0.94,
            latencyMode: .lowestLatency,
            now: 10.02
        )

        #expect(pressure.budgetDecision?.reason == .encodedFrame)
        #expect(controller.recentCleanPFrameBaselineWireBytes == cleanBaseline)
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

    @Test("Recovery feedback cuts only with loss or corroborating transport evidence")
    func recoveryFeedbackCutsOnlyWithLossOrCorroboratingTransportEvidence() {
        var controller = HostAdaptivePFrameController()
        func update(
            sequence: UInt64,
            reassemblyBacklogFrames: Int = 0,
            reassemblyBacklogBytes: Int = 0,
            recoveryState: MirageMediaFeedbackRecoveryState = .idle,
            now: CFAbsoluteTime
        ) -> HostFrameBudgetDecision? {
            controller.update(
                with: receiverFeedback(
                    sequence: sequence,
                    reassemblyBacklogFrames: reassemblyBacklogFrames,
                    reassemblyBacklogBytes: reassemblyBacklogBytes,
                    recoveryState: recoveryState
                ),
                currentBitrateBps: 60_000_000,
                requestedTargetBitrateBps: 60_000_000,
                startupCeilingBps: 60_000_000,
                minimumBitrateFloorBps: 2_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_200,
                currentQuality: 0.60,
                qualityFloor: 0.03,
                steadyQualityCeiling: 0.90,
                now: now
            )
        }

        let backlogDecision = update(
            sequence: 1,
            reassemblyBacklogFrames: 1,
            reassemblyBacklogBytes: 16 * 1024,
            now: 10
        )
        let startupRecoveryDecision = update(sequence: 2, recoveryState: .startup, now: 10.1)
        // Idle-screen freeze recovery: keyframeRecovery with zero loss and zero
        // transport evidence must not cut the budget.
        let uncorroboratedRecoveryDecision = update(
            sequence: 3,
            recoveryState: .keyframeRecovery,
            now: 10.2
        )
        let corroboratedRecoveryDecision = update(
            sequence: 4,
            reassemblyBacklogFrames: 2,
            reassemblyBacklogBytes: 64 * 1024,
            recoveryState: .keyframeRecovery,
            now: 12.0
        )

        #expect(backlogDecision == nil)
        #expect(startupRecoveryDecision == nil)
        #expect(uncorroboratedRecoveryDecision == nil)
        #expect(corroboratedRecoveryDecision?.reason == .clientRecovery)
        #expect(corroboratedRecoveryDecision?.state == .pressured)
        // Without loss, keyframe recovery cuts the startup probe budget (64 KiB)
        // at the bounded recovery scale, not the severe panic scale.
        let startupBudgetBytes = 64 * 1024
        let recoveryScaleBytes = Int((Double(startupBudgetBytes) * 0.70).rounded(.down))
        #expect(corroboratedRecoveryDecision?.maxWireBytes == recoveryScaleBytes)
        #expect(corroboratedRecoveryDecision?.targetBitrateBps == bitrate(forFrameBytes: recoveryScaleBytes))
    }

    @Test("Hard recovery with transport evidence keeps the severe panic cut")
    func hardRecoveryWithTransportEvidenceKeepsSeverePanicCut() throws {
        var controller = HostAdaptivePFrameController()
        let optionalDecision = controller.update(
            with: receiverFeedback(
                sequence: 1,
                reassemblyBacklogFrames: 3,
                reassemblyBacklogBytes: 128 * 1024,
                recoveryState: .hardRecovery
            ),
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
        let decision = try #require(optionalDecision)

        #expect(decision.reason == .clientRecovery)
        #expect(decision.state == .severe)
        #expect(decision.targetBitrateBps <= Int(Double(60_000_000) * 0.46))
    }

    @Test("Cut detectors coalesce within one event window instead of compounding")
    func cutDetectorsCoalesceWithinOneEventWindow() throws {
        var controller = HostAdaptivePFrameController()
        func deadlineDrop(now: CFAbsoluteTime) -> HostFrameBudgetDecision? {
            controller.recordSenderDeadlineDrop(
                currentBitrateBps: 60_000_000,
                requestedTargetBitrateBps: 60_000_000,
                startupCeilingBps: 60_000_000,
                minimumBitrateFloorBps: 2_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_200,
                currentQuality: 0.60,
                qualityFloor: 0.03,
                steadyQualityCeiling: 0.90,
                now: now
            )
        }
        func freshnessPressure(now: CFAbsoluteTime) -> HostFrameBudgetDecision? {
            controller.recordFreshnessPressure(
                currentBitrateBps: 60_000_000,
                requestedTargetBitrateBps: 60_000_000,
                startupCeilingBps: 60_000_000,
                minimumBitrateFloorBps: 2_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_200,
                currentQuality: 0.60,
                qualityFloor: 0.03,
                steadyQualityCeiling: 0.90,
                now: now
            )
        }

        let first = try #require(deadlineDrop(now: 10))
        // A different detector in the same event window deepens only to its own
        // scale of the pre-event target, never multiplicatively below it.
        let second = try #require(freshnessPressure(now: 10.2))
        // The same detector repeating in the window is a no-op.
        let third = try #require(deadlineDrop(now: 10.4))
        // Outside the window, cuts apply normally again.
        let fourth = try #require(deadlineDrop(now: 12.0))

        // Fresh controllers start from the 64 KiB lowestLatency startup budget.
        let preEventBytes = Double(64 * 1024)
        #expect(first.maxWireBytes == Int((preEventBytes * 0.70).rounded(.down)))
        #expect(second.maxWireBytes == Int((preEventBytes * 0.55).rounded(.down)))
        #expect(third.maxWireBytes == second.maxWireBytes)
        #expect(fourth.maxWireBytes < third.maxWireBytes)
    }

    @Test("Startup transport protection bounds deadline-drop cuts to one bounded step")
    func startupTransportProtectionBoundsDeadlineDropCuts() throws {
        var controller = HostAdaptivePFrameController()
        func deadlineDrop(
            startupProtectionActive: Bool,
            now: CFAbsoluteTime
        ) -> HostFrameBudgetDecision? {
            controller.recordSenderDeadlineDrop(
                currentBitrateBps: 64_000_000,
                requestedTargetBitrateBps: 64_000_000,
                startupCeilingBps: 153_000_000,
                minimumBitrateFloorBps: 8_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_200,
                currentQuality: 0.60,
                qualityFloor: 0.03,
                steadyQualityCeiling: 0.90,
                startupProtectionActive: startupProtectionActive,
                now: now
            )
        }

        let first = try #require(deadlineDrop(startupProtectionActive: true, now: 10))
        #expect(first.state == .pressured)
        // Bounded to the grace scale (0.70) of the 64 KiB startup budget — not the
        // severe compounding collapse seen in the field.
        let startupBudgetBytes = Double(64 * 1024)
        #expect(first.maxWireBytes >= Int((startupBudgetBytes * 0.69).rounded(.down)))

        let second = deadlineDrop(startupProtectionActive: true, now: 10.3)
        #expect(second == nil)

        let postStartup = try #require(deadlineDrop(startupProtectionActive: false, now: 16))
        #expect(postStartup.state == .severe)
        #expect(postStartup.targetBitrateBps < first.targetBitrateBps)
    }

    @Test("Proven capacity lets input samples jump past the per-sample ramp step")
    func provenCapacityLetsInputSamplesJumpPastPerSampleRampStep() throws {
        var controller = HostAdaptivePFrameController()
        let decision = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: 60_000_000,
            requestedBitrate: 60_000_000,
            startupCeiling: 180_000_000,
            minimumFloor: 3_000_000,
            inputActive: true,
            sourceStill: false,
            wireBytes: 36 * 1024,
            packetSpanMs: 2,
            completionGapMs: 2,
            currentQuality: 0.50
        ))

        #expect(decision.reason == .healthy)
        // The lowestLatency startup budget is 64 KiB; the legacy input step allowed
        // ~3.5% growth per sample, the capacity-backed jump allows 12%.
        #expect(decision.maxWireBytes >= Int(Double(64 * 1024) * 1.10))
    }

    @Test("Motion onset clamps idle-ramped budget back to learned realtime capacity")
    func motionOnsetClampsIdleRampedBudgetToLearnedRealtimeCapacity() throws {
        var controller = HostAdaptivePFrameController()
        // Learn a modest path capacity from a real delivery sample.
        _ = try #require(recordDelivery(
            controller: &controller,
            currentBitrate: 24_000_000,
            requestedBitrate: 300_000_000,
            startupCeiling: 300_000_000,
            minimumFloor: 2_000_000,
            inputActive: true,
            sourceStill: false,
            wireBytes: 60_000,
            packetSpanMs: 20,
            completionGapMs: 20,
            currentQuality: 0.40,
            now: 10
        ))
        // Idle ramp: still samples drive the budget far beyond proven capacity.
        var currentBitrate = 24_000_000
        var currentQuality: Float = 0.40
        for frameNumber in 2...12 {
            guard let decision = recordDelivery(
                controller: &controller,
                frameNumber: UInt64(frameNumber),
                currentBitrate: currentBitrate,
                requestedBitrate: 300_000_000,
                startupCeiling: 300_000_000,
                minimumFloor: 2_000_000,
                inputActive: false,
                sourceStill: true,
                wireBytes: 12 * 1024,
                packetSpanMs: 2,
                completionGapMs: 2,
                currentQuality: currentQuality,
                now: 10 + Double(frameNumber) * 0.25
            ) else { continue }
            currentBitrate = decision.targetBitrateBps
            currentQuality = decision.quality
        }
        let rampedTarget = try #require(controller.operatingTargetWireBytes)

        let optionalClampDecision = controller.prepareForMotionOnset(
            currentBitrateBps: currentBitrate,
            requestedTargetBitrateBps: 300_000_000,
            startupCeilingBps: 300_000_000,
            minimumBitrateFloorBps: 2_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: currentQuality,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            now: 14
        )
        let clampDecision = try #require(optionalClampDecision)

        #expect(clampDecision.reason == .motionOnset)
        #expect(clampDecision.state == .observing)
        #expect(clampDecision.maxWireBytes < rampedTarget)
        #expect(clampDecision.targetBitrateBps < currentBitrate)

        // Already clamped: a second onset in the same state is a no-op.
        let repeatDecision = controller.prepareForMotionOnset(
            currentBitrateBps: clampDecision.targetBitrateBps,
            requestedTargetBitrateBps: 300_000_000,
            startupCeilingBps: 300_000_000,
            minimumBitrateFloorBps: 2_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: clampDecision.quality,
            qualityFloor: 0.03,
            steadyQualityCeiling: 0.90,
            now: 14.1
        )
        #expect(repeatDecision == nil)
    }

    @Test("Cumulative receiver loss feedback only cuts on new loss deltas")
    func cumulativeReceiverLossFeedbackOnlyCutsOnNewLossDeltas() {
        var controller = HostAdaptivePFrameController()
        func update(
            sequence: UInt64,
            lostFrameCount: UInt64,
            now: CFAbsoluteTime
        ) -> HostFrameBudgetDecision? {
            controller.update(
                with: receiverFeedback(sequence: sequence, lostFrameCount: lostFrameCount),
                currentBitrateBps: 60_000_000,
                requestedTargetBitrateBps: 60_000_000,
                startupCeilingBps: 60_000_000,
                minimumBitrateFloorBps: 2_000_000,
                currentFrameRate: 60,
                maxPayloadSize: 1_200,
                currentQuality: 0.60,
                qualityFloor: 0.03,
                steadyQualityCeiling: 0.90,
                now: now
            )
        }

        #expect(update(sequence: 1, lostFrameCount: 0, now: 10) == nil)
        #expect(update(sequence: 2, lostFrameCount: 1, now: 10.1)?.reason == .receiverLoss)
        #expect(update(sequence: 3, lostFrameCount: 1, now: 10.2) == nil)
        #expect(update(sequence: 4, lostFrameCount: 2, now: 10.3)?.reason == .receiverLoss)
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

    @Test("Transport backlog pressure trims P-frame budget without collapsing recovery quality")
    func transportBacklogPressureTrimsPFrameBudgetWithoutCollapsingRecoveryQuality() throws {
        var controller = HostAdaptivePFrameController()
        let optionalDecision = controller.recordTransportBacklogPressure(
            severe: false,
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
        let decision = try #require(optionalDecision)

        #expect(decision.reason == .transportBacklog)
        #expect(decision.state == .pressured)
        #expect(decision.targetBitrateBps < 60_000_000)
        #expect(decision.quality > 0.40)
        #expect(decision.keyframeQuality > decision.quality)
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
    deliveryMode: HostFrameDeliveryMode = .realtime,
    capacityLearningAllowed: Bool = true,
    completionAgeAtFeedbackMs: Double = 0,
    wireBytes: Int,
    packetSpanMs: Double,
    completionGapMs: Double,
    currentQuality: Float = 0.60,
    latencyMode: MirageStreamLatencyMode = .lowestLatency,
    mediaPathProfile: MirageMediaPathProfile = .unknown,
    receiverPlayoutDelayTargetMs: Double? = nil,
    awdlQualityReductionAllowed: Bool = true,
    currentFrameRate: Int = 60,
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
        deliveryMode: deliveryMode,
        currentBitrateBps: currentBitrate,
        requestedTargetBitrateBps: requestedBitrate,
        startupCeilingBps: startupCeiling,
        minimumBitrateFloorBps: minimumFloor,
        currentFrameRate: currentFrameRate,
        maxPayloadSize: 1_200,
        currentQuality: currentQuality,
        qualityFloor: 0.03,
        steadyQualityCeiling: 0.90,
        latencyMode: latencyMode,
        mediaPathProfile: mediaPathProfile,
        receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs,
        awdlQualityReductionAllowed: awdlQualityReductionAllowed,
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
