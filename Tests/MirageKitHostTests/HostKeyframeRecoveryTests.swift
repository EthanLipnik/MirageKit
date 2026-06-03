//
//  HostKeyframeRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Host keyframe recovery, FEC, and quality coverage.
//

@testable import MirageKitHost
import MirageKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing

#if os(macOS)
@Suite("Host Keyframe Recovery")
struct HostKeyframeRecoveryTests {
    @Test("Recovery keyframe requests do not escalate into host hard resets")
    func recoveryRequestsDoNotEscalateIntoHostHardResets() async throws {
        let context = makeContext()

        await context.requestKeyframeRecoveryIfPossible()
        #expect(await context.softRecoveryCount == 1)
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(await context.pendingKeyframeRequiresFlush == false)

        try await Task.sleep(for: .milliseconds(1100))
        await context.requestKeyframeRecoveryIfPossible()
        #expect(await context.softRecoveryCount == 2)
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(await context.pendingKeyframeRequiresFlush == false)

        try await Task.sleep(for: .milliseconds(1100))
        await context.requestKeyframeRecoveryIfPossible()
        #expect(await context.softRecoveryCount == 3)
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(await context.pendingKeyframeRequiresFlush == false)
    }

    @Test("Decode-error and freeze-timeout keyframe requests bypass adaptive cooldown")
    func decodeErrorAndFreezeTimeoutKeyframeRequestsBypassAdaptiveCooldown() async {
        let context = makeContext()

        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())

        let frameLossAck = await context.requestKeyframe(recoveryCause: .frameLoss)
        #expect(!frameLossAck.accepted)

        let freezeAck = await context.requestKeyframe(recoveryCause: .freezeTimeout)
        #expect(freezeAck.accepted)

        let decodeContext = makeContext()
        await decodeContext.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())

        let decodeAck = await decodeContext.requestKeyframe(recoveryCause: .decodeError)
        #expect(decodeAck.accepted)
        #expect(await decodeContext.pendingKeyframeReason == "Keyframe request")
    }

    @Test("Memory-budget keyframe requests are suppressed")
    func memoryBudgetKeyframeRequestsAreSuppressed() async {
        let context = makeContext()
        await context.recordCaptureIngress(makeIdleFrame())
        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        await context.markKeyframeInFlight(frameNumber: 0)

        let ack = await context.requestKeyframe(recoveryCause: .memoryBudget)

        #expect(!ack.accepted)
        #expect(await context.pendingKeyframeReason == nil)
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(await context.pendingKeyframeRequiresFlush == false)
        #expect(context.epoch == 0)
        #expect(context.frameInbox.pendingCount == 0)
    }

    @Test("Startup-timeout keyframe requests bypass adaptive cooldown")
    func startupTimeoutKeyframeRequestsBypassAdaptiveCooldown() async {
        let context = makeContext()
        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())

        let ack = await context.requestKeyframe(recoveryCause: .startupTimeout)

        #expect(ack.accepted)
        #expect(await context.pendingKeyframeReason == "Keyframe request")
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(await context.pendingKeyframeRequiresFlush == false)
    }

    @Test("AWDL geometry recovery bypasses cooldown and in-flight keyframe window")
    func awdlGeometryRecoveryBypassesCooldownAndInFlightKeyframeWindow() async {
        let context = makeContext(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        await context.markKeyframeInFlight(frameNumber: 41)

        let accepted = await context.scheduleCoalescedRecoveryKeyframe(
            reason: "Desktop resize reset",
            noteLoss: true,
            requiresFlush: true,
            requiresReset: true,
            supersedesInFlightGeometry: true,
            bypassesRecoveryCooldown: true
        )

        #expect(accepted)
        #expect(await context.pendingKeyframeReason == "Desktop resize reset")
        #expect(await context.keyframeInFlightFrameNumber == nil)
        #expect(await context.keyframeSendDeadline == 0)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, frameByteCount: 64 * 1024, now: CFAbsoluteTimeGetCurrent()) == 4)
    }

    @Test("AWDL geometry recovery supersedes pending non-geometry keyframe")
    func awdlGeometryRecoverySupersedesPendingNonGeometryKeyframe() async {
        let context = makeContext(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )

        await context.queueKeyframeIfPossible(
            reason: "Stale recovery",
            checkInFlight: false,
            urgent: true
        )
        #expect(await context.pendingKeyframeReason == "Stale recovery")

        let accepted = await context.scheduleCoalescedRecoveryKeyframe(
            reason: "Desktop resize reset",
            noteLoss: true,
            requiresFlush: true,
            requiresReset: true,
            supersedesInFlightGeometry: true,
            bypassesRecoveryCooldown: true
        )

        #expect(accepted)
        #expect(await context.pendingKeyframeReason == "Desktop resize reset")
        #expect(await context.pendingKeyframeRequiresReset)
        #expect(await context.pendingKeyframeRequiresFlush)
    }

    @Test("AWDL sender dependency drop bypasses adaptive keyframe cooldown")
    func awdlSenderDependencyDropBypassesAdaptiveKeyframeCooldown() async {
        let context = makeContext(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        await context.configureRunningForRepairRetryTest()
        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())

        await context.handlePacketSenderDependencyFrameDrop(
            streamID: 1,
            frameNumber: 12,
            reason: .queueEviction
        )

        #expect(await context.pendingKeyframeReason == "Packet sender dependency drop")
        #expect(await context.pendingKeyframeRequiresFlush)
        #expect(await context.pendingKeyframeRequiresReset)
        #expect(await context.dependencyRecoveryRetryNecessary == false)
        #expect(context.currentFrameRate == 45)
        #expect(await !context.currentAwdlQualityReductionAllowed())
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
    }

    @Test("Running decode-error recovery drains synthetic keyframe frame")
    func runningDecodeErrorRecoveryDrainsSyntheticKeyframeFrame() async throws {
        let context = makeContext()
        await context.configureRunningForRepairRetryTest()
        await context.recordCaptureIngress(makeIdleFrame())

        let ack = await context.requestKeyframe(recoveryCause: .decodeError)

        #expect(ack.accepted)
        try await waitForSyntheticFrameDrain(on: context)
        await context.stop()
    }

    @Test("Startup-gated synthetic recovery frame drains after encoding opens")
    func startupGatedSyntheticRecoveryFrameDrainsAfterEncodingOpens() async throws {
        let context = makeContext()
        await context.recordCaptureIngress(makeIdleFrame())

        let ack = await context.requestKeyframe(recoveryCause: .decodeError)

        #expect(ack.accepted)
        #expect(context.frameInbox.pendingCount == 1)

        await context.configureRunningForRepairRetryTest()
        await context.scheduleProcessingIfNeeded()

        try await waitForSyntheticFrameDrain(on: context)
        await context.stop()
    }

    @Test("Receiver decode-recovery feedback schedules keyframe even when explicit request is lost")
    func receiverDecodeRecoveryFeedbackSchedulesKeyframe() async {
        let context = makeContext()

        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                recoveryState: .keyframeRecovery,
                recoveryCause: .decodeError
            )
        )

        #expect(await context.pendingKeyframeReason == "Receiver feedback keyframe recovery")
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
    }

    @Test("Receiver no-progress freeze feedback with transport evidence schedules keyframe")
    func receiverNoProgressFreezeFeedbackWithTransportEvidenceSchedulesKeyframe() async {
        let context = makeContext()

        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                recoveryState: .keyframeRecovery,
                recoveryCause: .freezeTimeout,
                reassemblerIncompleteFrameTimeouts: 1,
                reliabilityCauses: [.noProgressTimeout]
            )
        )

        #expect(await context.pendingKeyframeReason == "Receiver feedback keyframe recovery")
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
    }

    @Test("Duplicate explicit keyframe requests are suppressed")
    func duplicateExplicitKeyframeRequestsAreSuppressed() async {
        let context = makeContext()

        let firstAck = await context.requestKeyframe(recoveryCause: .decodeError)
        let secondAck = await context.requestKeyframe(recoveryCause: .decodeError)

        #expect(firstAck.accepted)
        #expect(!secondAck.accepted)
        #expect(await context.softRecoveryCount == 1)
    }

    @Test("Receiver keyframe-starvation alone is not transport evidence")
    func receiverKeyframeStarvationAloneIsNotTransportEvidence() async {
        let context = makeContext()

        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                recoveryState: .keyframeRecovery,
                recoveryCause: .freezeTimeout,
                reliabilityCauses: [.keyframeStarvation]
            )
        )

        #expect(await context.pendingKeyframeReason == nil)
        #expect(!context.suppressEncodedNonKeyframesUntilKeyframe)
    }

    @Test("Receiver startup-timeout feedback bypasses adaptive cooldown")
    func receiverStartupTimeoutFeedbackBypassesAdaptiveCooldown() async {
        let context = makeContext()

        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                recoveryState: .startup,
                recoveryCause: .startupTimeout
            )
        )

        #expect(await context.pendingKeyframeReason == "Receiver feedback keyframe recovery")
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
    }

    @Test("Receiver post-resize feedback bypasses adaptive cooldown")
    func receiverPostResizeFeedbackBypassesAdaptiveCooldown() async {
        let context = makeContext()

        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                recoveryState: .postResizeAwaitingFirstFrame,
                recoveryCause: .manual
            )
        )

        #expect(await context.pendingKeyframeReason == "Receiver feedback keyframe recovery")
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
    }

    @Test("AWDL receiver post-resize feedback bypasses in-flight geometry keyframe window")
    func awdlReceiverPostResizeFeedbackBypassesInFlightGeometryKeyframeWindow() async {
        let context = makeContext(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )

        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        await context.markKeyframeInFlight(frameNumber: 88)
        #expect(await context.keyframeSendDeadline > CFAbsoluteTimeGetCurrent())

        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                recoveryState: .postResizeAwaitingFirstFrame,
                recoveryCause: .manual
            )
        )

        #expect(await context.pendingKeyframeReason == "Receiver feedback keyframe recovery")
        #expect(await context.keyframeInFlightFrameNumber == nil)
        #expect(await context.keyframeSendDeadline == 0)
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
    }

    @Test("AWDL receiver post-resize feedback supersedes pending non-geometry keyframe")
    func awdlReceiverPostResizeFeedbackSupersedesPendingNonGeometryKeyframe() async {
        let context = makeContext(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )

        await context.queueKeyframeIfPossible(
            reason: "Stale recovery",
            checkInFlight: false,
            urgent: true
        )
        #expect(await context.pendingKeyframeReason == "Stale recovery")

        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                recoveryState: .postResizeAwaitingFirstFrame,
                recoveryCause: .manual
            )
        )

        #expect(await context.pendingKeyframeReason == "Receiver feedback keyframe recovery")
        #expect(await context.pendingKeyframeRequiresReset)
        #expect(await context.pendingKeyframeRequiresFlush)
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
    }

    @Test("Recovery keyframe waits for receiver acknowledgement before resuming P-frames")
    func recoveryKeyframeWaitsForReceiverAcknowledgementBeforeResumingPFrames() async throws {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()
        await context.setFrameChainStateForTesting(
            .emergencyKeyframePending(reason: "unit-test", openedAt: now),
            suppressPFrames: true
        )

        await context.handleFrameTransportCompleted(
            frameTransportCompletion(frameNumber: 44, isKeyframe: true, didSend: true, now: now)
        )

        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
        let stateAfterSend = await context.frameChainState
        guard case .emergencyKeyframePending = stateAfterSend else {
            Issue.record("Expected repair to remain pending until receiver acknowledgement")
            return
        }

        await context.handleFrameTransportCompleted(
            frameTransportCompletion(frameNumber: 45, isKeyframe: false, didSend: true, now: now + 0.01)
        )

        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
        let stateAfterCleanPFrame = await context.frameChainState
        guard case .emergencyKeyframePending = stateAfterCleanPFrame else {
            Issue.record("Expected clean P-frame completion to stay blocked before receiver acknowledgement")
            return
        }

        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                sequence: 2,
                recoveryState: .idle,
                recoveryCause: .none,
                ackRanges: [MediaFeedbackFrameRange(startFrame: 44, endFrame: 44)]
            )
        )

        #expect(!context.suppressEncodedNonKeyframesUntilKeyframe)
        let acceptedState = await context.frameChainState
        guard case let .postKeyframeCooling(remaining) = acceptedState else {
            Issue.record("Expected post-keyframe cooling after receiver acknowledgement")
            return
        }
        let expectedCoolingFrames = await context.postEmergencyKeyframeCleanPFrameCount
        #expect(remaining == expectedCoolingFrames)
    }

    @Test("Recovery keyframe accepts idle receiver presentation evidence")
    func recoveryKeyframeAcceptsIdleReceiverPresentationEvidence() async throws {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()
        await context.setFrameChainStateForTesting(
            .emergencyKeyframePending(reason: "unit-test", openedAt: now),
            suppressPFrames: true
        )

        await context.handleFrameTransportCompleted(
            frameTransportCompletion(frameNumber: 44, isKeyframe: true, didSend: true, now: now - 0.20)
        )

        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                sequence: 2,
                recoveryState: .idle,
                recoveryCause: .none,
                latestAcceptedFrameNumber: 44,
                latestPresentedFrameNumber: 44
            )
        )

        #expect(!context.suppressEncodedNonKeyframesUntilKeyframe)
        let acceptedState = await context.frameChainState
        guard case let .postKeyframeCooling(remaining) = acceptedState else {
            Issue.record("Expected post-keyframe cooling after receiver presentation evidence")
            return
        }
        let expectedCoolingFrames = await context.postEmergencyKeyframeCleanPFrameCount
        #expect(remaining == expectedCoolingFrames)
    }

    @Test("Dropped transport P-frame starts dependency chain repair")
    func droppedTransportPFrameStartsDependencyChainRepair() async {
        let context = makeContext()
        await context.configureRunningForRepairRetryTest()
        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        let now = CFAbsoluteTimeGetCurrent()

        await context.handleFrameTransportCompleted(
            frameTransportCompletion(frameNumber: 45, isKeyframe: false, didSend: false, now: now)
        )

        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
        #expect(await context.pendingKeyframeReason == "Packet sender dependency drop")
        #expect(await context.pendingKeyframeRequiresFlush)
        #expect(await context.pendingKeyframeRequiresReset)
        #expect(await context.dependencyRecoveryPendingDropFrameNumber == 45)
        #expect(await context.dependencyRecoveryPendingDropReason == .transportDrop)
        #expect(await context.dependencyRecoveryRetryNecessary == false)
        let state = await context.frameChainState
        guard case .emergencyKeyframePending = state else {
            Issue.record("Expected dropped transport P-frame to queue emergency keyframe repair")
            return
        }
    }

    @Test("Emergency repair keyframe carries discontinuity reset")
    func emergencyRepairKeyframeCarriesDiscontinuityReset() async {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()

        await context.startFrameChainRepair(
            reason: "unit-test",
            firstBrokenFrame: 40,
            now: now
        )
        let queued = await context.scheduleEmergencyChainRepairKeyframe(
            reason: "unit-test",
            bypassesRecoveryCooldown: true,
            now: now
        )

        #expect(queued)
        #expect(await context.pendingKeyframeRequiresReset)
        #expect(await context.pendingKeyframeRequiresFlush)
        #expect(context.epoch == 1)
        #expect(context.dynamicFrameFlags.contains(.discontinuity))
    }

    @Test("Emergency repair keyframe arms progress retry while running")
    func emergencyRepairKeyframeArmsProgressRetryWhileRunning() async {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()
        await context.configureRunningForRepairRetryTest()
        await context.startFrameChainRepair(
            reason: "unit-test",
            firstBrokenFrame: 40,
            now: now
        )

        let queued = await context.scheduleEmergencyChainRepairKeyframe(
            reason: "unit-test",
            bypassesRecoveryCooldown: true,
            now: now
        )

        #expect(queued)
        #expect(await context.pendingKeyframeReason == "unit-test")
        #expect(await context.frameChainRepairKeyframeRetryTask != nil)

        await context.stop()
    }

    @Test("Low-latency high-res boost keeps a modest encoder-speed bias at 600 Mbps")
    func lowLatencyHighResBoostKeepsModestEncoderSpeedBiasAtHighBitrate() async {
        let boostedContext = makeContext(
            frameRate: 60,
            bitrate: 600_000_000,
            runtimeQualityAdjustmentEnabled: false,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let baselineContext = makeContext(
            frameRate: 60,
            bitrate: 600_000_000,
            runtimeQualityAdjustmentEnabled: false,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: false
        )
        let fiveKSize = CGSize(width: 5120, height: 2880)
        await boostedContext.updateCaptureSizesIfNeeded(fiveKSize)
        await boostedContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)
        await baselineContext.updateCaptureSizesIfNeeded(fiveKSize)
        await baselineContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)

        let boosted = await boostedContext.activeQuality
        let baseline = await baselineContext.activeQuality
        #expect(boosted >= 0.82)
        #expect(boosted < baseline)
        #expect(abs(boosted - baseline) < 0.10)
    }

    @Test("Low-latency high-res boost remains aggressive at 25 Mbps")
    func lowLatencyHighResBoostStaysAggressiveWhenConstrained() async {
        let boostedContext = makeContext(
            frameRate: 60,
            bitrate: 25_000_000,
            runtimeQualityAdjustmentEnabled: false,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let baselineContext = makeContext(
            frameRate: 60,
            bitrate: 25_000_000,
            runtimeQualityAdjustmentEnabled: false,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: false
        )
        let fiveKSize = CGSize(width: 5120, height: 2880)
        await boostedContext.updateCaptureSizesIfNeeded(fiveKSize)
        await boostedContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)
        await baselineContext.updateCaptureSizesIfNeeded(fiveKSize)
        await baselineContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)

        let boosted = await boostedContext.activeQuality
        let baseline = await baselineContext.activeQuality
        #expect(boosted <= 0.06)
        #expect(boosted + 0.07 < baseline)
    }

    @Test("Runtime bitrate raises quality ceiling without active quality jump")
    func runtimeBitrateRaisesQualityCeilingWithoutActiveQualityJump() async {
        let context = makeContext(
            frameRate: 60,
            bitrate: 32_000_000,
            runtimeQualityAdjustmentEnabled: true,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let displaySize = CGSize(width: 2752, height: 2064)
        await context.updateCaptureSizesIfNeeded(displaySize)
        await context.applyDerivedQuality(for: displaySize, logLabel: nil)

        let startupQuality = await context.activeQuality
        #expect(startupQuality < 0.50)

        await context.refreshRuntimeQualityTargets(
            for: 180_000_000,
            reason: HostAdaptivePFrameController.Reason.healthy.rawValue
        )

        let raisedQuality = await context.activeQuality
        #expect(abs(raisedQuality - startupQuality) < 0.0001)
        #expect(await context.configuredQualityCeiling >= 0.70)
        #expect(await context.qualityCeiling >= 0.70)
    }

    @Test("Runtime recovery cuts do not collapse configured quality ceiling")
    func runtimeRecoveryCutsDoNotCollapseConfiguredQualityCeiling() async {
        let context = makeContext(
            frameRate: 60,
            bitrate: 32_000_000,
            runtimeQualityAdjustmentEnabled: true,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let displaySize = CGSize(width: 2752, height: 2064)
        await context.updateCaptureSizesIfNeeded(displaySize)
        await context.applyDerivedQuality(for: displaySize, logLabel: nil)

        let startupQuality = await context.activeQuality
        let startupConfiguredCeiling = await context.configuredQualityCeiling

        await context.refreshRuntimeQualityTargets(
            for: 4_800_000,
            reason: HostAdaptivePFrameController.Reason.clientRecovery.rawValue
        )

        let cutQuality = await context.activeQuality
        let configuredCeilingAfterCut = await context.configuredQualityCeiling
        let qualityCeilingAfterCut = await context.qualityCeiling
        #expect(cutQuality < startupQuality)
        #expect(abs(configuredCeilingAfterCut - startupConfiguredCeiling) < 0.0001)
        #expect(qualityCeilingAfterCut < startupConfiguredCeiling)
    }

    @Test("AWDL runtime recovery keeps readable quality floor")
    func awdlRuntimeRecoveryKeepsReadableQualityFloor() async {
        let context = makeContext(
            frameRate: 60,
            bitrate: 24_000_000,
            runtimeQualityAdjustmentEnabled: true,
            latencyMode: .balanced,
            lowLatencyHighResolutionCompressionBoostEnabled: true,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let displaySize = CGSize(width: 2752, height: 2064)
        await context.updateCaptureSizesIfNeeded(displaySize)
        await context.applyDerivedQuality(for: displaySize, logLabel: nil)

        let now = CFAbsoluteTimeGetCurrent()
        await context.applyFrameBudgetDecision(
            HostFrameBudgetDecision(
                targetBitrateBps: 8_000_000,
                maxFrameBytes: 64 * 1024,
                maxWireBytes: 64 * 1024,
                maxPacketCount: 64,
                quality: 0.04,
                qualityCeiling: 0.04,
                keyframeQuality: 0.04,
                sendDeadline: now + 1,
                state: .severe,
                reason: .clientRecovery
            ),
            now: now
        )

        #expect(await context.qualityCeiling >= 0.16)
        #expect(await context.qualityFloor >= 0.16)
        #expect(await context.keyframeQualityFloor >= 0.14)
        #expect(await context.activeQuality >= 0.16)
    }

    @Test("AWDL derived quality keeps startup and retune above readability floor")
    func awdlDerivedQualityKeepsStartupAndRetuneAboveReadabilityFloor() async {
        let context = makeContext(
            frameRate: 60,
            bitrate: 18_000_000,
            runtimeQualityAdjustmentEnabled: true,
            latencyMode: .balanced,
            lowLatencyHighResolutionCompressionBoostEnabled: true,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let displaySize = CGSize(width: 2752, height: 2064)
        await context.updateCaptureSizesIfNeeded(displaySize)
        await context.applyDerivedQuality(for: displaySize, logLabel: nil)

        #expect(await context.encoderConfig.frameQuality >= 0.16)
        #expect(await context.encoderConfig.keyframeQuality >= 0.14)
        #expect(await context.configuredQualityCeiling >= 0.16)
        #expect(await context.qualityCeiling >= 0.16)
        #expect(await context.qualityFloor >= 0.16)
        #expect(await context.keyframeQualityFloor >= 0.14)
        #expect(await context.activeQuality >= 0.16)

        await context.refreshRuntimeQualityTargets(
            for: 4_800_000,
            reason: HostAdaptivePFrameController.Reason.clientRecovery.rawValue
        )

        #expect(await context.encoderConfig.frameQuality >= 0.16)
        #expect(await context.encoderConfig.keyframeQuality >= 0.14)
        #expect(await context.qualityCeiling >= 0.16)
        #expect(await context.qualityFloor >= 0.16)
        #expect(await context.keyframeQualityFloor >= 0.14)
        #expect(await context.activeQuality >= 0.16)
    }

    @Test("Adaptive-off streams ignore receiver-feedback budget cuts")
    func adaptiveOffStreamsIgnoreReceiverFeedbackBudgetCuts() async {
        let context = makeContext(
            frameRate: 60,
            bitrate: 300_000_000,
            runtimeQualityAdjustmentEnabled: false,
            latencyMode: .lowestLatency
        )
        let displaySize = CGSize(width: 2752, height: 2064)
        await context.updateCaptureSizesIfNeeded(displaySize)
        await context.applyDerivedQuality(for: displaySize, logLabel: nil)

        let startupCeiling = await context.qualityCeiling
        let now = CFAbsoluteTimeGetCurrent()

        // A severe receiver-panic budget decision (what client loss/freeze
        // recovery produces). With adaptive quality OFF the host must honor the
        // user's settings and drop frames instead of cutting bitrate/quality.
        await context.applyFrameBudgetDecision(
            HostFrameBudgetDecision(
                targetBitrateBps: 12_000_000,
                maxFrameBytes: 64 * 1024,
                maxWireBytes: 64 * 1024,
                maxPacketCount: 64,
                quality: 0.04,
                qualityCeiling: 0.04,
                keyframeQuality: 0.04,
                sendDeadline: now + 1,
                state: .severe,
                reason: .clientRecovery
            ),
            now: now
        )

        #expect(await context.qualityCeiling == startupCeiling)
    }

    @Test("AWDL manual-quality streams keep quality but apply pacing safety")
    func awdlManualQualityStreamsKeepQualityButApplyPacingSafety() async {
        let context = makeContext(
            frameRate: 60,
            bitrate: 300_000_000,
            runtimeQualityAdjustmentEnabled: false,
            latencyMode: .balanced,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let displaySize = CGSize(width: 2752, height: 2064)
        await context.updateCaptureSizesIfNeeded(displaySize)
        await context.applyDerivedQuality(for: displaySize, logLabel: nil)

        let startupQuality = await context.activeQuality
        let startupCeiling = await context.qualityCeiling
        let startupBitrate = await context.encoderSettings.bitrate
        let now = CFAbsoluteTimeGetCurrent()

        await context.applyFrameBudgetDecision(
            HostFrameBudgetDecision(
                targetBitrateBps: 8_000_000,
                maxFrameBytes: 64 * 1024,
                maxWireBytes: 64 * 1024,
                maxPacketCount: 64,
                quality: 0.04,
                qualityCeiling: 0.04,
                keyframeQuality: 0.04,
                sendDeadline: now + 1,
                state: .severe,
                reason: .receiverLoss
            ),
            now: now
        )

        #expect(await context.activeQuality == startupQuality)
        #expect(await context.qualityCeiling == startupCeiling)
        #expect(await context.encoderSettings.bitrate == startupBitrate)
        #expect(await context.realtimeRuntimeQualityCeiling == nil)
        #expect(await context.realtimeSenderPacingBitrateBps == 6_000_000)
    }

    @Test("Bitrate-capped 6K streams allow a lower runtime quality floor")
    func bitrateCappedQualityFloor() async {
        let context = makeContext(
            frameRate: 120,
            bitrate: 120_000_000
        )
        let sixKSize = CGSize(width: 6016, height: 3384)
        await context.updateCaptureSizesIfNeeded(sixKSize)
        await context.applyDerivedQuality(for: sixKSize, logLabel: nil)

        let floor = await context.qualityFloor
        #expect(floor < 0.1)
    }

    @Test("Recovery keyframe quality does not drop under queue pressure")
    func keyframeQualityDoesNotDropUnderQueuePressure() async {
        let context = makeContext(
            frameRate: 120,
            bitrate: 300_000_000
        )
        let sixKSize = CGSize(width: 6016, height: 3384)
        await context.updateCaptureSizesIfNeeded(sixKSize)
        await context.applyDerivedQuality(for: sixKSize, logLabel: nil)

        let baseline = await context.keyframeQuality
        let pressured = await context.keyframeQuality

        #expect(abs(baseline - pressured) < 0.0001)
    }

    @Test("Runtime-quality-disabled streams keep keyframe quality fixed under queue pressure")
    func keyframeQualityStaysFixedWhenRuntimeAdjustmentDisabled() async {
        let context = makeContext(
            frameRate: 120,
            bitrate: 120_000_000,
            runtimeQualityAdjustmentEnabled: false
        )
        let sixKSize = CGSize(width: 6016, height: 3384)
        await context.updateCaptureSizesIfNeeded(sixKSize)
        await context.applyDerivedQuality(for: sixKSize, logLabel: nil)

        let baseline = await context.keyframeQuality
        let pressured = await context.keyframeQuality

        #expect(abs(baseline - pressured) < 0.0001)
    }

    @Test("Recovery keyframe requests enter protected loss-mode FEC")
    func recoveryRequestsEnterProtectedLossModeFEC() async throws {
        let context = makeContext()

        await context.requestKeyframeRecoveryIfPossible()
        let softTime = CFAbsoluteTimeGetCurrent()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: softTime) == 8)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: softTime) == 16)

        try await Task.sleep(for: .milliseconds(1100))
        await context.requestKeyframeRecoveryIfPossible()
        let secondSoftTime = CFAbsoluteTimeGetCurrent()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: secondSoftTime) == 8)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: secondSoftTime) == 16)
    }

    @Test("Startup transport protection strengthens keyframe FEC")
    func startupTransportProtectionStrengthensKeyframeFEC() async {
        let context = makeContext()

        await context.enableStartupTransportProtection(now: 10.0)
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: 10.0) == 4)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: 10.0) == 0)
        #expect(StreamContext.keyframePacingOverride() == StreamPacketSender.PacingOverride(
            rateBps: 48_000_000,
            burstBytes: 16 * 1024
        ))

        await context.disableStartupTransportProtection()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: 10.0) == 0)
    }

    @Test("AWDL startup keyframes use bounded FEC block")
    func awdlStartupKeyframesUseBoundedFECBlock() async {
        let context = makeContext(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )

        await context.enableStartupTransportProtection(now: 10.0)

        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: 10.0) == 4)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: 10.0) == 0)
    }

    @Test("AWDL recovery loss mode protects P-frames with bounded FEC")
    func awdlRecoveryLossModeProtectsPFramesWithBoundedFEC() async {
        let context = makeContext(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let beforeLoss = CFAbsoluteTimeGetCurrent()
        #expect(context.resolvedFECBlockSize(isKeyframe: false, frameByteCount: 64 * 1024, now: beforeLoss) == 0)

        await context.noteLossEvent(reason: "unit-test", enablePFrameFEC: true)
        let lossTime = CFAbsoluteTimeGetCurrent()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: lossTime) == 4)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, frameByteCount: 64 * 1024, now: lossTime) == 4)
    }

    @Test("AWDL receiver recovery policy protects P-frames before legacy loss mode")
    func awdlReceiverRecoveryPolicyProtectsPFramesBeforeLegacyLossMode() async {
        let context = makeContext(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let feedback = receiverRecoveryFeedback(
            recoveryState: .keyframeRecovery,
            recoveryCause: .frameLoss
        )

        await context.applyReceiverMediaFeedback(feedback)

        #expect(context.lossModeDeadline == 0)
        #expect(context.lossModePFrameFECDeadline == 0)
        #expect(context.resolvedFECBlockSize(
            isKeyframe: false,
            frameByteCount: 64 * 1024,
            now: CFAbsoluteTimeGetCurrent()
        ) == 4)
    }

    @Test("Startup keyframe stays separate from recovery loss mode")
    func startupKeyframeDoesNotEnterRecoveryLossMode() async {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()

        await context.enableStartupTransportProtection(now: now)
        await context.scheduleCoalescedStartupKeyframe(
            reason: "Startup registration confirmed",
            resetFrameNumber: true
        )

        #expect(await context.pendingKeyframeReason == "Startup registration confirmed")
        #expect(context.lossModeDeadline == 0)
        #expect(context.lossModePFrameFECDeadline == 0)
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: now) == 4)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: now) == 0)
    }

    @Test("Steady-state idle capture frames stay out of encode inbox")
    func steadyStateIdleFramesStayOutOfEncodeInbox() async {
        let context = makeContext()

        await context.recordCaptureIngress(makeIdleFrame())

        #expect(context.frameInbox.pendingCount == 0)
        #expect(await context.lastCapturedFrame?.info.isIdleFrame == true)
    }

    @Test("Recovery keyframe requests synthesize cached idle frame")
    func recoveryKeyframeRequestsSynthesizeCachedIdleFrame() async {
        let context = makeContext()

        await context.recordCaptureIngress(makeIdleFrame())
        _ = await context.requestKeyframe()

        #expect(context.frameInbox.pendingCount == 1)
        #expect(await context.pendingKeyframeReason == "Keyframe request")
    }

    @Test("Still quality probe synthesizes cached idle frame without SCK input")
    func stillQualityProbeSynthesizesCachedIdleFrameWithoutSCKInput() async {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()

        await context.recordCaptureIngress(makeIdleFrame())
        await context.applyFrameBudgetDecision(
            HostFrameBudgetDecision(
                targetBitrateBps: 8_000_000,
                maxFrameBytes: 16 * 1024,
                maxWireBytes: 16 * 1024,
                maxPacketCount: 14,
                quality: 0.10,
                qualityCeiling: 0.10,
                keyframeQuality: 0.10,
                sendDeadline: now + 1,
                state: .pressured,
                reason: .pFrameLatency
            ),
            now: now
        )
        let scheduled = await context.scheduleStillQualityProbeIfNeeded(
            now: now + 1.0,
            reason: "test"
        )

        #expect(scheduled)
        #expect(context.frameInbox.pendingCount == 1)
    }

    @Test("Keyframe packet pacing override caps send rate and burst budget")
    func startupPacketPacingCapsKeyframeBurstBudget() {
        let pacingOverride = StreamContext.keyframePacingOverride()
        let startupParameters = StreamPacketSender.packetPacingParameters(
            targetRateBps: 76_000_000,
            packetBytes: 1_500,
            isKeyframeBurst: true,
            totalFragments: 1_200,
            pacingOverride: pacingOverride
        )
        let steadyStateParameters = StreamPacketSender.packetPacingParameters(
            targetRateBps: 76_000_000,
            packetBytes: 1_500,
            isKeyframeBurst: true,
            totalFragments: 1_200,
            pacingOverride: nil
        )

        #expect(startupParameters != nil)
        #expect(steadyStateParameters != nil)
        #expect(Int(startupParameters?.burstBytes ?? 0) == pacingOverride.burstBytes)
        #expect((startupParameters?.bytesPerSecond ?? 0) < (steadyStateParameters?.bytesPerSecond ?? 0))
        #expect((startupParameters?.burstBytes ?? 0) <
            (startupParameters?.bytesPerSecond ?? 0) / 1_000.0 * StreamPacketSender.packetPacerBurstWindowMs)
    }

    @Test("AWDL media pacing gives keyframes a bounded recovery budget and narrows P-frame bursts")
    func awdlMediaPacingGivesKeyframesBoundedRecoveryBudgetAndNarrowsPFrameBursts() {
        let keyframeOverride = StreamContext.keyframePacingOverride(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            targetBitrateBps: 24_000_000,
            maxPayloadSize: 1_200
        )
        let pFrameOverride = StreamContext.mediaPacingOverride(
            isKeyframe: false,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            targetBitrateBps: 24_000_000,
            maxPayloadSize: 1_200
        )

        #expect(keyframeOverride.rateBps == 32_000_000)
        #expect(keyframeOverride.burstBytes == 4_800)
        #expect(pFrameOverride?.rateBps == 24_000_000)
        #expect(pFrameOverride?.burstBytes == 2_400)

        var controller = MirageAwdlMediaController()
        let decision = controller.update(
            with: MirageAwdlMediaController.Signal(
                mediaPathProfile: .awdlRadio,
                currentFrameRate: 60,
                targetFrameRate: 60,
                targetBitrateBps: 18_000_000
            )
        )
        let decisionKeyframeOverride = StreamContext.keyframePacingOverride(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            targetBitrateBps: nil,
            maxPayloadSize: 1_200,
            awdlDecision: decision
        )
        let decisionPFrameOverride = StreamContext.mediaPacingOverride(
            isKeyframe: false,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            targetBitrateBps: nil,
            maxPayloadSize: 1_200,
            awdlDecision: decision
        )

        #expect(decisionKeyframeOverride.rateBps == decision.keyframePacingBudgetBps)
        #expect(decisionPFrameOverride?.rateBps == decision.hostPacingBudgetBps)
    }

    private func makeContext(
        frameRate: Int = 60,
        bitrate: Int = 600_000_000,
        runtimeQualityAdjustmentEnabled: Bool = true,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        lowLatencyHighResolutionCompressionBoostEnabled: Bool = true,
        transportPathKind: MirageNetworkPathKind = .unknown,
        mediaPathProfile: MirageMediaPathProfile? = nil
    ) -> StreamContext {
        let encoderConfig = MirageEncoderConfiguration(
            targetFrameRate: frameRate,
            keyFrameInterval: 1800,
            colorDepth: .pro,
            colorSpace: .displayP3,
            pixelFormat: .bgr10a2,
            bitrate: bitrate
        )
        return StreamContext(
            streamID: 1,
            windowID: 1,
            encoderConfig: encoderConfig,
            streamScale: 1.0,
            runtimeQualityAdjustmentEnabled: runtimeQualityAdjustmentEnabled,
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyHighResolutionCompressionBoostEnabled,
            latencyMode: latencyMode,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
    }

    private func makeIdleFrame() -> CapturedFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8,
            8,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        guard let pixelBuffer else {
            Issue.record("Failed to create CVPixelBuffer")
            fatalError("Failed to create CVPixelBuffer")
        }

        return CapturedFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: CMTime(value: 1, timescale: 60),
            duration: CMTime(value: 1, timescale: 60),
            captureTime: CFAbsoluteTimeGetCurrent(),
            info: CapturedFrameInfo(
                contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
                dirtyPercentage: 0,
                isIdleFrame: true
            )
        )
    }

    private func waitForSyntheticFrameDrain(on context: StreamContext) async throws {
        let deadline = CFAbsoluteTimeGetCurrent() + 1.0
        while CFAbsoluteTimeGetCurrent() < deadline {
            let pendingKeyframeReason = await context.pendingKeyframeReason
            if context.frameInbox.pendingCount == 0, pendingKeyframeReason == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let pendingKeyframeReason = await context.pendingKeyframeReason ?? "nil"
        Issue.record(
            "Expected synthetic keyframe frame to drain; pending=\(context.frameInbox.pendingCount), pendingKeyframeReason=\(pendingKeyframeReason)"
        )
    }

    private func receiverRecoveryFeedback(
        sequence: UInt64 = 1,
        recoveryState: MirageMediaFeedbackRecoveryState,
        recoveryCause: MirageMediaFeedbackRecoveryCause,
        ackRanges: [MediaFeedbackFrameRange] = [],
        reassemblerIncompleteFrameTimeouts: UInt64? = nil,
        reliabilityCauses: [ReceiverMediaFeedbackReliabilityCause] = [],
        latestAcceptedFrameNumber: UInt32? = nil,
        latestPresentedFrameNumber: UInt32? = nil
    ) -> ReceiverMediaFeedbackMessage {
        ReceiverMediaFeedbackMessage(
            streamID: 1,
            sequence: sequence,
            sentAtUptime: CFAbsoluteTimeGetCurrent(),
            targetFPS: 60,
            ackRanges: ackRanges,
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
            decodedFPS: 0,
            receivedFPS: 0,
            rendererAcceptedFPS: 0,
            rendererPresentedFPS: 0,
            recoveryState: recoveryState,
            recoveryCause: recoveryCause,
            reassemblerIncompleteFrameTimeouts: reassemblerIncompleteFrameTimeouts,
            reliabilityCauses: reliabilityCauses,
            latestAcceptedFrameNumber: latestAcceptedFrameNumber,
            latestPresentedFrameNumber: latestPresentedFrameNumber
        )
    }

    private func frameTransportCompletion(
        frameNumber: UInt32,
        isKeyframe: Bool,
        didSend: Bool,
        now: CFAbsoluteTime
    ) -> StreamPacketSender.FrameTransportCompletion {
        StreamPacketSender.FrameTransportCompletion(
            streamID: 1,
            frameNumber: frameNumber,
            isKeyframe: isKeyframe,
            didSend: didSend,
            frameByteCount: isKeyframe ? 48_000 : 12_000,
            wireBytes: isKeyframe ? 50_000 : 13_000,
            packetCount: isKeyframe ? 38 : 10,
            queuedUnreliableDropCounts: didSend ? QueuedUnreliableDropCounts() : QueuedUnreliableDropCounts(deadlineExpired: 1),
            dimensionToken: 0,
            encodedAt: now - 0.006,
            startedAt: now - 0.004,
            completedAt: now
        )
    }
}

private extension StreamContext {
    func setLastSuccessfulKeyframeSendTimeForTesting(_ time: CFAbsoluteTime) {
        lastSuccessfulKeyframeSendTime = time
    }

    func setFrameChainStateForTesting(
        _ state: HostFrameChainState,
        suppressPFrames: Bool
    ) {
        frameChainState = state
        suppressEncodedNonKeyframesUntilKeyframe = suppressPFrames
    }

    func configureRunningForRepairRetryTest() {
        isRunning = true
        shouldEncodeFrames = true
    }
}
#endif
