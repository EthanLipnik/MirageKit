//
//  StreamContext+ReceiverMediaFeedback.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
private struct ReceiverPFrameTimingApplication {
    let frameBudgetDecision: HostFrameBudgetDecision?
    let structuralPressure: HostPFrameTimingPressureSignal?
}

extension StreamContext {
    func applyReceiverMediaFeedback(_ feedback: ReceiverMediaFeedbackMessage) async {
        let now = CFAbsoluteTimeGetCurrent()
        lastReceiverFeedbackTime = now
        receiverReassemblyBacklogFrames = feedback.reassemblyBacklogFrames
        receiverReassemblyBacklogBytes = feedback.reassemblyBacklogBytes
        receiverDecodeBacklogFrames = feedback.decodeQueueDepth ?? feedback.decodeBacklogFrames
        receiverPresentationBacklogFrames = resolvedReceiverPresentationBacklogFrames(feedback)
        receiverLatestAcceptedFrameNumber = feedback.latestAcceptedFrameNumber
        receiverLatestPresentedFrameNumber = feedback.latestPresentedFrameNumber
        receiverLatestPresentedFrameAgeMs = feedback.latestPresentedFrameAgeMs
        receiverLostFrameCount = feedback.lostFrameCount
        receiverDiscardedPacketCount = feedback.discardedPacketCount
        latestReceiverRecoveryCause = feedback.recoveryCause
        updateReceiverCapacityLearningQuarantine(feedback, now: now)
        let ackFrameBudgetDecision = applyReceiverFrameAcknowledgements(feedback.ackRanges, now: now)
        let senderTelemetry = await packetSender?.telemetrySnapshot
        let transportDecision = transportController.update(
            with: feedback,
            currentFrameRate: currentFrameRate,
            requestedFrameRateCeiling: awdlInteractiveFrameRateCeiling,
            targetBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile,
            senderTelemetry: senderTelemetry,
            now: now
        )
        latestAwdlMediaDecisionSnapshot = transportController.latestAwdlMediaDecision
        if latestAwdlMediaDecisionSnapshot?.qualityReductionAllowed == true {
            grantAwdlHostStructuralQualityReduction(now: now, reason: "receiver-policy-survival")
        }
        updateReceiverPlayoutDelayTarget(
            feedbackTargetMs: feedback.playoutDelayTargetMs,
            transportDecision: transportDecision
        )
        let awdlQualityReductionAllowed = currentAwdlQualityReductionAllowed(now: now)
        let pFrameTimingDecision = applyReceiverPFrameTimingSamples(
            feedback.pFrameTimingSamples,
            awdlQualityReductionAllowed: awdlQualityReductionAllowed,
            now: now
        )
        let frameBudgetDecision = adaptivePFrameController.update(
            with: feedback,
            currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            requestedTargetBitrateBps: requestedTargetBitrate,
            startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
            minimumBitrateFloorBps: realtimeMinimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: activeQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: configuredQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs,
            awdlQualityReductionAllowed: awdlQualityReductionAllowed,
            now: now
        )
        if mediaPathProfile.usesAwdlRadioPolicy {
            await logAwdlReceiverFeedbackIfNeeded(
                now: now,
                feedback: feedback,
                decision: transportDecision
            )
        }

        if let transportDecision {
            await applyTransportFeedbackDecision(transportDecision, now: now)
        }
        if let structuralPressure = pFrameTimingDecision.structuralPressure,
           pFrameTimingDecision.frameBudgetDecision == nil,
           transportDecision?.awdlTargetFrameRate == nil,
           transportDecision?.awdlResolutionScale == nil {
            await applyAwdlReceiverPFrameTimingStructuralPressure(
                structuralPressure,
                now: now
            )
        }
        if mediaPathProfile.usesAwdlRadioPolicy {
            await retryPendingAwdlInteractiveFrameRateIfNeeded(now: now)
            await retryPendingAwdlInteractiveScaleIfNeeded(now: now)
        }
        if let frameBudgetDecision {
            await applyFrameBudgetDecision(frameBudgetDecision, now: now)
        }
        if let ackFrameBudgetDecision {
            await applyFrameBudgetDecision(ackFrameBudgetDecision, now: now)
        }
        if let pFrameTimingDecision = pFrameTimingDecision.frameBudgetDecision {
            await applyFrameBudgetDecision(pFrameTimingDecision, now: now)
        }
        noteReceiverAcceptedKeyframeIfNeeded(feedback, now: now)
        noteReceiverPresentationRecoveryEvidenceIfNeeded(feedback, now: now)
        scheduleStillQualityProbeIfNeeded(now: now, reason: "receiver-feedback")
        await scheduleReceiverFeedbackKeyframeRecoveryIfNeeded(feedback, now: now)
    }

    func currentAwdlFrameBudgetReductionAllowed(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Bool {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return true }
        guard awdlHostEncoderStructuralQualityReductionAllowed else {
            return false
        }
        guard now <= awdlHostEncoderStructuralQualityReductionDeadline else {
            clearAwdlHostStructuralQualityReduction()
            return false
        }
        let cadenceDemoted = currentFrameRate <= 30
        let baseScale = awdlInteractiveBaseStreamScale ?? requestedStreamScale
        let scaleMultiplier = baseScale > 0 ? Double(streamScale / baseScale) : 1.0
        let resolutionDemoted = scaleMultiplier <= 0.751
        return cadenceDemoted && resolutionDemoted
    }

    func currentAwdlQualityReductionAllowed(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Bool {
        runtimeQualityAdjustmentEnabled && currentAwdlFrameBudgetReductionAllowed(now: now)
    }

    func grantAwdlHostStructuralQualityReduction(
        now: CFAbsoluteTime,
        reason: String
    ) {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return }
        let grantStart = max(now, CFAbsoluteTimeGetCurrent())
        awdlHostEncoderStructuralQualityReductionAllowed = true
        awdlHostEncoderStructuralQualityReductionDeadline = max(
            awdlHostEncoderStructuralQualityReductionDeadline,
            grantStart + awdlHostEncoderStructuralQualityReductionHold
        )
        MirageLogger.metrics(
            "AWDL survival quality window for stream \(streamID): " +
                "reason=\(reason) expiresAt=\(awdlHostEncoderStructuralQualityReductionDeadline)"
        )
    }

    func clearAwdlHostStructuralQualityReduction() {
        awdlHostEncoderStructuralQualityReductionAllowed = false
        awdlHostEncoderStructuralQualityReductionDeadline = 0
    }

    func resolvedReceiverPresentationBacklogFrames(_ feedback: ReceiverMediaFeedbackMessage) -> Int {
        let queueBacklog = feedback.presentationQueueDepth.map { queueDepth in
            guard let targetFrames = feedback.presentationTargetFrames else { return 0 }
            return max(0, queueDepth - targetFrames)
        } ?? 0
        return max(0, feedback.presentationBacklogFrames, queueBacklog)
    }

    private func scheduleReceiverFeedbackKeyframeRecoveryIfNeeded(
        _ feedback: ReceiverMediaFeedbackMessage,
        now: CFAbsoluteTime
    ) async {
        let needsKeyframe: Bool = switch feedback.recoveryState {
        case .keyframeRecovery,
             .hardRecovery,
             .postResizeAwaitingFirstFrame:
            true
        case .startup:
            feedback.recoveryCause == .startupTimeout
        case .idle,
             .tierPromotionProbe:
            false
        }
        guard needsKeyframe else { return }
        let hasTransportRecoveryEvidence = receiverFeedbackHasTransportRecoveryEvidence(feedback)
        let hasConfirmedNoProgressFreeze = receiverFeedbackHasConfirmedNoProgressFreeze(feedback)
        if feedback.recoveryCause == .freezeTimeout,
           !hasTransportRecoveryEvidence,
           !hasConfirmedNoProgressFreeze {
            MirageLogger.stream(
                "Receiver freeze keyframe recovery ignored for stream \(streamID) without transport evidence"
            )
            return
        }
        guard feedback.recoveryCause.allowsReceiverFeedbackKeyframeRecovery else {
            MirageLogger.stream(
                "Receiver feedback keyframe recovery ignored for non-decode cause " +
                    "\(feedback.recoveryCause.rawValue) on stream \(streamID)"
            )
            return
        }
        let supersedesInFlightGeometry = mediaPathProfile.usesAwdlRadioPolicy &&
            feedback.recoveryState == .postResizeAwaitingFirstFrame
        if supersedesInFlightGeometry {
            frameChainRepairKeyframeRetryTask?.cancel()
            frameChainRepairKeyframeRetryTask = nil
        }
        guard (supersedesInFlightGeometry || pendingKeyframeReason == nil),
              (supersedesInFlightGeometry || now >= keyframeSendDeadline),
              !isKeyframeEncoding,
              (supersedesInFlightGeometry || frameChainRepairKeyframeRetryTask == nil) else {
            return
        }
        if case .emergencyKeyframePending = frameChainState {
            return
        }

        let bypassesCooldown = feedback.recoveryState == .postResizeAwaitingFirstFrame ||
            recoveryCauseBypassesAdaptiveKeyframeCooldown(feedback.recoveryCause) ||
            (feedback.recoveryCause == .freezeTimeout && (hasTransportRecoveryEvidence || hasConfirmedNoProgressFreeze))
        let reason = "Receiver feedback keyframe recovery"
        startFrameChainRepair(
            reason: "receiver-feedback-\(feedback.recoveryCause.rawValue)",
            now: now
        )
        await noteEmergencyKeyframePrepared(using: nil)
        let queued = await scheduleEmergencyChainRepairKeyframe(
            reason: reason,
            bypassesRecoveryCooldown: bypassesCooldown,
            supersedesInFlightGeometry: supersedesInFlightGeometry,
            now: now
        )
        MirageLogger.stream(
            "\(reason) for stream \(streamID) recovery=\(feedback.recoveryState.rawValue) " +
            "cause=\(feedback.recoveryCause.rawValue) queued=\(queued)"
        )
    }

    private func receiverFeedbackHasTransportRecoveryEvidence(_ feedback: ReceiverMediaFeedbackMessage) -> Bool {
        feedback.lostFrameCount > 0 ||
            feedback.discardedPacketCount > 0 ||
            feedback.reassemblyBacklogFrames > 0 ||
            feedback.reassemblyBacklogBytes > 0 ||
            (feedback.reassemblerIncompleteFrameTimeouts ?? 0) > 0 ||
            (feedback.reassemblerMissingFragmentTimeouts ?? 0) > 0 ||
            (feedback.reassemblerForwardGapTimeouts ?? 0) > 0 ||
            feedback.reliabilityCauses.contains(.forwardGapStall) ||
            feedback.reliabilityCauses.contains(.noProgressTimeout)
    }

    private func receiverFeedbackHasConfirmedNoProgressFreeze(_ feedback: ReceiverMediaFeedbackMessage) -> Bool {
        guard feedback.recoveryCause == .freezeTimeout,
              feedback.recoveryState == .keyframeRecovery || feedback.recoveryState == .hardRecovery else {
            return false
        }
        let presentedAgeMs = feedback.latestPresentedFrameAgeMs ?? 0
        return presentedAgeMs >= 1_500 &&
            feedback.receivedFPS <= 0.5 &&
            feedback.decodedFPS <= 0.5
    }

    private func applyReceiverFrameAcknowledgements(
        _ ranges: [MediaFeedbackFrameRange],
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard !ranges.isEmpty else { return nil }

        var newestAckedFrame = receiverAcknowledgedFrameNumber
        for range in ranges where isFrameNumber(range.endFrame, newerThan: newestAckedFrame) {
            newestAckedFrame = range.endFrame
        }
        guard let ackedFrame = newestAckedFrame,
              isFrameNumber(ackedFrame, newerThan: receiverAcknowledgedFrameNumber) else {
            return nil
        }

        receiverAcknowledgedFrameNumber = ackedFrame
        lastReceiverAckTime = now
        if let completion = recentFrameTransportCompletions.last(where: { $0.frameNumber == ackedFrame }) {
            receiverAckLagMs = max(0, (now - completion.completedAt) * 1000)
        }
        noteReceiverAcceptedKeyframeIfNeeded(in: ranges, now: now)
        return nil
    }

    private func noteReceiverAcceptedKeyframeIfNeeded(
        in ranges: [MediaFeedbackFrameRange],
        now: CFAbsoluteTime
    ) {
        guard let pendingReceiverAcceptedKeyframeFrameNumber else { return }
        guard ranges.contains(where: {
            frameNumber(pendingReceiverAcceptedKeyframeFrameNumber, isInside: $0)
        }) else {
            return
        }
        handleReceiverAcceptedKeyframe(
            frameNumber: pendingReceiverAcceptedKeyframeFrameNumber,
            evidence: "ack",
            now: now
        )
    }

    private func noteReceiverAcceptedKeyframeIfNeeded(
        _ feedback: ReceiverMediaFeedbackMessage,
        now: CFAbsoluteTime
    ) {
        guard let pendingFrameNumber = pendingReceiverAcceptedKeyframeFrameNumber else { return }
        let acceptedFrame = feedback.latestAcceptedFrameNumber
        let presentedFrame = feedback.latestPresentedFrameNumber
        guard acceptedFrame.map({ receiverFrame($0, covers: pendingFrameNumber) }) == true ||
            presentedFrame.map({ receiverFrame($0, covers: pendingFrameNumber) }) == true else {
            return
        }
        handleReceiverAcceptedKeyframe(
            frameNumber: pendingFrameNumber,
            evidence: "receiver-feedback-latest-frame",
            now: now
        )
    }

    private func receiverFrame(_ latestFrame: UInt32, covers pendingFrame: UInt32) -> Bool {
        latestFrame == pendingFrame || isFrameNumber(latestFrame, newerThan: pendingFrame)
    }

    private func frameNumber(_ frameNumber: UInt32, isInside range: MediaFeedbackFrameRange) -> Bool {
        if range.startFrame <= range.endFrame {
            return frameNumber >= range.startFrame && frameNumber <= range.endFrame
        }
        return frameNumber >= range.startFrame || frameNumber <= range.endFrame
    }

    private func noteReceiverPresentationRecoveryEvidenceIfNeeded(
        _ feedback: ReceiverMediaFeedbackMessage,
        now: CFAbsoluteTime
    ) {
        guard let pendingFrameNumber = pendingReceiverAcceptedKeyframeFrameNumber,
              feedback.recoveryState == .idle,
              !receiverFeedbackHasTransportRecoveryEvidence(feedback),
              let completion = recentFrameTransportCompletions.last(where: {
                  $0.frameNumber == pendingFrameNumber && $0.isKeyframe && $0.didSend
              }),
              now - completion.completedAt >= 0.10 else {
            return
        }
        handleReceiverAcceptedKeyframe(
            frameNumber: pendingFrameNumber,
            evidence: "idle-feedback",
            now: now
        )
    }

    private func applyReceiverPFrameTimingSamples(
        _ samples: [ReceiverPFrameTimingSample],
        awdlQualityReductionAllowed: Bool,
        now: CFAbsoluteTime
    ) -> ReceiverPFrameTimingApplication {
        guard runtimeQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy,
              !samples.isEmpty else {
            _ = adaptivePFrameController.consumeQualityGatedPFramePressure()
            return ReceiverPFrameTimingApplication(frameBudgetDecision: nil, structuralPressure: nil)
        }
        _ = adaptivePFrameController.consumeQualityGatedPFramePressure()
        var latestDecision: HostFrameBudgetDecision?
        let canLearnCapacity = receiverFrameBudgetCanLearnCapacity(now: now)
        let quarantineReason = receiverFrameBudgetCapacityLearningQuarantineReason(now: now)
        let inputActive = inputIsActive(now: now)
        let sourceStill = sourceIsStill(now: now)
        var matchedSampleCount = 0
        var missingCompletionCount = 0
        var decisionCount = 0
        var latestSampleFrame: UInt32?
        for sample in samples {
            latestSampleFrame = sample.frameNumber
            guard let completion = recentFrameTransportCompletions.last(where: {
                $0.frameNumber == sample.frameNumber && !$0.isKeyframe && $0.didSend
            }) else {
                missingCompletionCount += 1
                continue
            }
            matchedSampleCount += 1
            let decision = adaptivePFrameController.recordFrameTransportCompletion(
                frameNumber: UInt64(completion.frameNumber),
                wireBytes: completion.wireBytes,
                packetCount: completion.packetCount,
                isKeyframe: false,
                sendCompletionMs: sample.packetSpanMs,
                packetSpanMs: sample.packetSpanMs,
                completionGapMs: sample.completionGapMs,
                completionAgeAtFeedbackMs: sample.completionAgeAtFeedbackMs,
                firstPacketGapMs: sample.firstPacketGapMs,
                timingSource: .clientAssembled,
                receiverHealthy: receiverFrameBudgetIsHealthy(now: now),
                capacityLearningAllowed: canLearnCapacity,
                inputActive: inputActive,
                sourceStill: sourceStill,
                currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
                requestedTargetBitrateBps: requestedTargetBitrate,
                startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
                minimumBitrateFloorBps: realtimeMinimumBitrateFloorBps,
                currentFrameRate: currentFrameRate,
                maxPayloadSize: maxPayloadSize,
                currentQuality: activeQuality,
                qualityFloor: qualityFloor,
                steadyQualityCeiling: configuredQualityCeiling,
                latencyMode: latencyMode,
                mediaPathProfile: mediaPathProfile,
                receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs,
                awdlQualityReductionAllowed: awdlQualityReductionAllowed,
                now: now
            )
            if let decision {
                latestDecision = decision
                decisionCount += 1
            }
        }
        logReceiverPFrameTimingSamplesIfNeeded(
            total: samples.count,
            matched: matchedSampleCount,
            missingCompletion: missingCompletionCount,
            decisions: decisionCount,
            latestFrame: latestSampleFrame,
            canLearnCapacity: canLearnCapacity,
            quarantineReason: quarantineReason,
            now: now
        )
        return ReceiverPFrameTimingApplication(
            frameBudgetDecision: latestDecision,
            structuralPressure: adaptivePFrameController.consumeQualityGatedPFramePressure()
        )
    }

    private func applyAwdlReceiverPFrameTimingStructuralPressure(
        _ signal: HostPFrameTimingPressureSignal,
        now: CFAbsoluteTime
    ) async {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return }
        realtimePressureState = .pressured
        realtimePressureReason = "receiver-p-frame-timing"
        let applied = await applyAwdlHostStructuralAdaptationIfNeeded(
            reason: "receiver-p-frame-timing",
            at: now
        )
        let deliveryText = signal.deliveryMs.formatted(.number.precision(.fractionLength(1)))
        let targetText = signal.targetClearMs.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.metrics(
            "AWDL receiver P-frame timing held quality for stream \(streamID): " +
                "structural adaptation \(applied ? "applied" : "pending-or-exhausted") " +
                "frame=\(signal.frameNumber) delivery=\(deliveryText)ms target=\(targetText)ms " +
                "packetSpan=\(signal.packetSpanMs.formatted(.number.precision(.fractionLength(1))))ms " +
                "completionGap=\(signal.completionGapMs.formatted(.number.precision(.fractionLength(1))))ms"
        )
    }

    private func logReceiverPFrameTimingSamplesIfNeeded(
        total: Int,
        matched: Int,
        missingCompletion: Int,
        decisions: Int,
        latestFrame: UInt32?,
        canLearnCapacity: Bool,
        quarantineReason: String?,
        now: CFAbsoluteTime
    ) {
        guard now - receiverPFrameTimingSampleLastLogTime >= 0.5 else { return }
        guard missingCompletion > 0 || decisions == 0 || quarantineReason != nil else { return }
        receiverPFrameTimingSampleLastLogTime = now
        let latestFrameText = latestFrame.map(String.init) ?? "none"
        MirageLogger.metrics(
            "event=receiver_p_frame_timing_samples stream=\(streamID) total=\(total) " +
                "matched=\(matched) missingCompletion=\(missingCompletion) decisions=\(decisions) " +
                "latestFrame=\(latestFrameText) canLearn=\(canLearnCapacity) " +
                "quarantine=\(quarantineReason ?? "none")"
        )
    }

    private func isFrameNumber(_ frameNumber: UInt32, newerThan current: UInt32?) -> Bool {
        guard let current else { return true }
        let difference = frameNumber &- current
        return difference != 0 && difference < 0x8000_0000
    }

    private func applyTransportFeedbackDecision(
        _ decision: HostStreamTransportController.Decision,
        now: CFAbsoluteTime
    ) async {
        if mediaPathProfile.usesAwdlRadioPolicy, decision.awdlPacingDeadline > now {
            await packetSender?.activateAwdlPressurePacing(
                until: decision.awdlPacingDeadline,
                reason: decision.awdlPacingTrigger.rawValue
            )
        }

        guard mediaPathProfile.usesAwdlRadioPolicy else { return }
        await applyAwdlInteractiveDisplayStep(decision, now: now)
    }

    private func applyAwdlInteractiveDisplayStep(
        _ decision: HostStreamTransportController.Decision,
        now: CFAbsoluteTime
    ) async {
        if let targetFPS = decision.awdlTargetFrameRate {
            await applyAwdlInteractiveFrameRate(targetFPS, now: now, reason: decision.awdlPolicyTrigger?.rawValue)
        }
        if let scale = decision.awdlResolutionScale {
            _ = await applyAwdlInteractiveScale(scale, now: now, reason: decision.awdlPolicyTrigger?.rawValue)
        }
    }

    private func updateReceiverPlayoutDelayTarget(
        feedbackTargetMs: Double?,
        transportDecision: HostStreamTransportController.Decision?
    ) {
        guard mediaPathProfile.usesAwdlRadioPolicy else {
            receiverPlayoutDelayTargetMs = feedbackTargetMs
            return
        }
        if let feedbackTargetMs {
            receiverPlayoutDelayTargetMs = feedbackTargetMs
            return
        }
        if let controllerTargetMs = transportDecision?.awdlPlayoutDelayMs ?? latestAwdlMediaDecisionSnapshot?.playoutDelayMs {
            receiverPlayoutDelayTargetMs = controllerTargetMs
        }
    }

    @discardableResult
    func applyAwdlInteractiveFrameRate(
        _ targetFPS: Int,
        now: CFAbsoluteTime,
        reason: String?
    ) async -> Bool {
        let clamped = max(1, min(60, targetFPS))
        guard clamped != currentFrameRate else {
            if clamped > 30 {
                clearAwdlHostStructuralQualityReduction()
            }
            pendingAwdlInteractiveFrameRate = nil
            pendingAwdlInteractiveFrameRateReason = nil
            return true
        }
        let isDemotion = clamped < currentFrameRate
        let cooldown: CFAbsoluteTime = isDemotion ? 1.0 : 8.0
        guard lastAwdlInteractiveFrameRateAdjustmentTime == 0 ||
            now - lastAwdlInteractiveFrameRateAdjustmentTime >= cooldown else {
            pendingAwdlInteractiveFrameRate = clamped
            pendingAwdlInteractiveFrameRateReason = reason
            return false
        }
        do {
            try await updateFrameRate(clamped, updatesAwdlInteractiveCeiling: false)
            if let onAwdlInteractiveDesktopGeometryUpdate {
                await onAwdlInteractiveDesktopGeometryUpdate(streamID)
            }
            lastAwdlInteractiveFrameRateAdjustmentTime = now
            if clamped > 30 {
                clearAwdlHostStructuralQualityReduction()
            }
            pendingAwdlInteractiveFrameRate = nil
            pendingAwdlInteractiveFrameRateReason = nil
            MirageLogger.metrics(
                "AWDL interactive cadence step for stream \(streamID): " +
                    "targetFPS=\(clamped) reason=\(reason ?? "policy")"
            )
            return true
        } catch {
            MirageLogger.error(.stream, error: error, message: "AWDL frame-rate step failed: ")
            pendingAwdlInteractiveFrameRate = clamped
            pendingAwdlInteractiveFrameRateReason = reason
            return false
        }
    }

    private func retryPendingAwdlInteractiveFrameRateIfNeeded(now: CFAbsoluteTime) async {
        guard let targetFPS = pendingAwdlInteractiveFrameRate else { return }
        _ = await applyAwdlInteractiveFrameRate(
            targetFPS,
            now: now,
            reason: pendingAwdlInteractiveFrameRateReason
        )
    }

    private func retryPendingAwdlInteractiveScaleIfNeeded(now: CFAbsoluteTime) async {
        guard let scale = pendingAwdlInteractiveResolutionScale else { return }
        _ = await applyAwdlInteractiveScale(
            scale,
            now: now,
            reason: pendingAwdlInteractiveScaleReason
        )
    }

    @discardableResult
    func applyAwdlInteractiveScale(
        _ resolutionScale: Double,
        now: CFAbsoluteTime,
        reason: String?
    ) async -> Bool {
        let multiplier = max(0.75, min(1.0, resolutionScale))
        let baseScale = awdlInteractiveBaseStreamScale ?? requestedStreamScale
        awdlInteractiveBaseStreamScale = baseScale
        let targetScale = CGFloat(Double(baseScale) * multiplier)
        guard abs(Double(targetScale - streamScale)) > 0.0001 else {
            if multiplier > 0.751 {
                clearAwdlHostStructuralQualityReduction()
            }
            pendingAwdlInteractiveResolutionScale = nil
            pendingAwdlInteractiveScaleReason = nil
            return true
        }
        let isDemotion = targetScale < streamScale
        let cooldown: CFAbsoluteTime = isDemotion ? 4.0 : 20.0
        guard lastAwdlInteractiveScaleAdjustmentTime == 0 ||
            now - lastAwdlInteractiveScaleAdjustmentTime >= cooldown else {
            pendingAwdlInteractiveResolutionScale = multiplier
            pendingAwdlInteractiveScaleReason = reason
            return false
        }
        do {
            try await updateEmergencyRecoveryScale(
                targetScale,
                reason: "awdl-\(reason ?? "interactive")",
                advancesDimensionToken: true
            )
            if let onAwdlInteractiveDesktopGeometryUpdate {
                await onAwdlInteractiveDesktopGeometryUpdate(streamID)
            }
            await prepareAwdlInteractiveScaleKeyframe(
                multiplier: multiplier,
                reason: reason
            )
            await encoder?.forceKeyframe()
            lastAwdlInteractiveScaleAdjustmentTime = now
            if multiplier > 0.751 {
                clearAwdlHostStructuralQualityReduction()
            }
            pendingAwdlInteractiveResolutionScale = nil
            pendingAwdlInteractiveScaleReason = nil
            MirageLogger.metrics(
                "AWDL interactive scale step for stream \(streamID): " +
                    "targetScale=\(String(format: "%.3f", Double(targetScale))) " +
                    "multiplier=\(String(format: "%.3f", multiplier)) reason=\(reason ?? "policy")"
            )
            return true
        } catch {
            MirageLogger.error(.stream, error: error, message: "AWDL scale step failed: ")
            pendingAwdlInteractiveResolutionScale = multiplier
            pendingAwdlInteractiveScaleReason = reason
            return false
        }
    }

    private func prepareAwdlInteractiveScaleKeyframe(
        multiplier: Double,
        reason: String?
    ) async {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return }
        let frameFloor = resolvedRuntimeQualityFloor(for: resolvedQualityCeiling)
        let floor = max(
            frameFloor,
            resolvedRuntimeKeyframeQualityFloor(for: resolvedQualityCeiling)
        )
        let boundedQuality = max(
            floor,
            min(
                keyframeQuality,
                activeQuality,
                resolvedQualityCeiling
            )
        )
        pendingEmergencyKeyframeQuality = boundedQuality
        await encoder?.prepareForKeyframe(quality: boundedQuality)
        MirageLogger.metrics(
            "AWDL interactive scale keyframe prepared for stream \(streamID): " +
                "quality=\(formatAwdlMetric(Double(boundedQuality))) " +
                "floor=\(formatAwdlMetric(Double(floor))) " +
                "multiplier=\(formatAwdlMetric(multiplier)) reason=\(reason ?? "policy")"
        )
    }

    func applyFrameBudgetDecision(
        _ decision: HostFrameBudgetDecision,
        now: CFAbsoluteTime
    ) async {
        // Adaptive quality off (custom settings): the user owns the tradeoff, so
        // never reduce bitrate, quality, or fps. Drop frames instead. Freeze/loss
        // recovery (keyframes, FEC, chain repair) runs via separate paths
        // (scheduleReceiverFeedbackKeyframeRecoveryIfNeeded, startFrameChainRepair)
        // and is intentionally left untouched here.
        realtimePressureState = decision.state
        realtimePressureReason = decision.reason.rawValue
        realtimeRuntimeBitrateCeilingBps = adaptivePFrameController.runtimeCeilingBps
        guard runtimeQualityAdjustmentEnabled else {
            await applyAwdlManualQualityFrameBudgetSafety(decision)
            logRealtimeBudgetDecisionIfNeeded(now: now, decision: decision)
            return
        }
        realtimeRuntimeQualityCeiling = decision.state == .observing ? nil : decision.qualityCeiling
        await applyRealtimeBudgetBitrate(
            decision.targetBitrateBps,
            ceilingBitrateBps: realtimeRuntimeBitrateCeilingBps,
            encoderRateHintBps: decision.targetBitrateBps,
            senderPacingBitrateBps: realtimeSenderPacingBitrate(for: decision),
            reason: decision.reason.rawValue
        )
        let qualityChanged = await applyFrameBudgetQuality(decision)
        if qualityChanged {
            queueStillQualityRefreshKeyframeIfNeeded(decision: decision, now: now)
        }

        logRealtimeBudgetDecisionIfNeeded(now: now, decision: decision)
    }

    private func applyAwdlManualQualityFrameBudgetSafety(_ decision: HostFrameBudgetDecision) async {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return }
        realtimeRuntimeQualityCeiling = nil
        let pacingBitrate = realtimeSenderPacingBitrate(for: decision)
        guard pacingBitrate > 0,
              pacingBitrate != realtimeSenderPacingBitrateBps else {
            return
        }
        realtimeSenderPacingBitrateBps = pacingBitrate
        await packetSender?.setTargetBitrateBps(pacingBitrate)
        MirageLogger.metrics(
            "AWDL manual-quality frame budget safety for stream \(streamID): " +
                "senderPacing=\(mirageFormattedMegabitRate(pacingBitrate)) " +
                "state=\(decision.state.rawValue) reason=\(decision.reason.rawValue)"
        )
    }

    private func realtimeSenderPacingBitrate(for decision: HostFrameBudgetDecision) -> Int {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return decision.targetBitrateBps }
        switch decision.state {
        case .observing:
            return decision.targetBitrateBps
        case .pressured:
            return max(8_000_000, Int((Double(decision.targetBitrateBps) * 0.82).rounded(.down)))
        case .severe,
             .recovery:
            return max(6_000_000, Int((Double(decision.targetBitrateBps) * 0.68).rounded(.down)))
        }
    }

    private func applyFrameBudgetQuality(_ decision: HostFrameBudgetDecision) async -> Bool {
        let previousQuality = activeQuality
        let proposedQualityCeiling: Float
        if decision.state == .observing {
            proposedQualityCeiling = min(resolvedQualityCeiling, steadyQualityCeiling)
        } else {
            proposedQualityCeiling = min(resolvedQualityCeiling, decision.qualityCeiling, steadyQualityCeiling)
        }
        qualityCeiling = resolvedRuntimeQualityCeiling(for: proposedQualityCeiling)
        let proposedKeyframeQualityCeiling = min(decision.keyframeQuality, qualityCeiling)
        let keyframeQualityCeiling = resolvedRuntimeKeyframeQualityCeiling(for: proposedKeyframeQualityCeiling)
        qualityFloor = resolvedRuntimeQualityFloor(for: qualityCeiling)
        keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(
            for: keyframeQualityCeiling
        )
        let decisionQuality = max(qualityFloor, min(qualityCeiling, decision.quality))
        activeQuality = decisionQuality
        guard abs(Double(activeQuality - previousQuality)) > 0.0001 else { return false }
        await encoder?.updateQuality(activeQuality)
        MirageLogger.metrics(
            "Frame budget updated quality for stream \(streamID): " +
                "active=\(formatAwdlMetric(Double(activeQuality))) " +
                "ceiling=\(formatAwdlMetric(Double(qualityCeiling))) reason=\(decision.reason.rawValue)"
        )
        return true
    }

    private func queueStillQualityRefreshKeyframeIfNeeded(
        decision: HostFrameBudgetDecision,
        now: CFAbsoluteTime
    ) {
        guard decision.state == .observing, decision.reason == .healthy else { return }
        let policy = activeFrameFreshnessPolicy
        guard sourceIsStill(now: now, policy: policy),
              !inputIsActive(now: now, policy: policy) else {
            return
        }
        guard now - lastStillQualityRefreshKeyframeTime >= policy.stillQualityKeyframeInterval else { return }
        let queued = queueKeyframe(
            reason: "Still quality refresh",
            checkInFlight: true,
            countsAgainstRecoveryBudget: false
        )
        if queued {
            lastStillQualityRefreshKeyframeTime = now
            shouldAdmitIdleQualityProbeFrame = true
            scheduleProcessingForPendingKeyframe(reason: "Still quality refresh", now: now)
        }
    }

    private func logRealtimeBudgetDecisionIfNeeded(
        now: CFAbsoluteTime,
        decision: HostFrameBudgetDecision
    ) {
        guard realtimeLastLoggedState != decision.state ||
            realtimeLastLoggedBitrateCeilingBps != realtimeRuntimeBitrateCeilingBps ||
            now - realtimeLastLogTime >= 2.0 else {
            return
        }
        realtimeLastLogTime = now
        realtimeLastLoggedState = decision.state
        realtimeLastLoggedBitrateCeilingBps = realtimeRuntimeBitrateCeilingBps

        let ceilingText = realtimeRuntimeBitrateCeilingBps
            .map { mirageFormattedMegabitRate($0) }
            ?? "unknown"
        let currentBitrateText = (currentTargetBitrateBps ?? encoderConfig.bitrate)
            .map { mirageFormattedMegabitRate($0) }
            ?? "auto"
        let qualityText = realtimeRuntimeQualityCeiling
            .map { formatAwdlMetric(Double($0)) }
            ?? "none"
        let cleanPFrameText = adaptivePFrameController.recentCleanPFrameBaselineWireBytes
            .map { "\($0)B" }
            ?? "none"
        MirageLogger.metrics(
            "Frame budget: stream=\(streamID) " +
                "state=\(decision.state.rawValue) reason=\(decision.reason.rawValue) " +
                "runtimeCeiling=\(ceilingText) currentBitrate=\(currentBitrateText) " +
                "qualityCeiling=\(qualityText) " +
                "frameBytes=\(decision.maxFrameBytes) wireBytes=\(decision.maxWireBytes) " +
                "packets=\(decision.maxPacketCount) cleanPFrameBaseline=\(cleanPFrameText)"
        )
    }

    private func mirageFormattedMegabitRate(_ bitrate: Int) -> String {
        let mbps = Double(bitrate) / 1_000_000.0
        return "\(mbps.formatted(.number.precision(.fractionLength(1))))Mbps"
    }

    private func logAwdlReceiverFeedbackIfNeeded(
        now: CFAbsoluteTime,
        feedback: ReceiverMediaFeedbackMessage,
        decision: HostStreamTransportController.Decision?
    ) async {
        let trigger = decision?.awdlPacingTrigger ?? decision?.pressureTrigger ?? .none
        let hasReceiverStress = trigger != .none ||
            feedback.recoveryState != .idle ||
            feedback.lostFrameCount > 0 ||
            feedback.discardedPacketCount > 0 ||
            feedback.reassemblyBacklogFrames > 0 ||
            feedback.reassemblyBacklogKeyframes > 0 ||
            (feedback.presentationStallCount ?? 0) > 0 ||
            (feedback.displayTickNoFrameCount ?? 0) > 0 ||
            (feedback.pendingFrameNotReadyDisplayTickCount ?? 0) > 0 ||
            (feedback.reassemblerForwardGapTimeouts ?? 0) > 0
        guard hasReceiverStress ||
            lastAwdlReceiverFeedbackLogTime == 0 ||
            now - lastAwdlReceiverFeedbackLogTime >= 1.0 ||
            trigger != lastAwdlReceiverFeedbackTrigger else {
            return
        }
        guard lastAwdlReceiverFeedbackLogTime == 0 ||
            now - lastAwdlReceiverFeedbackLogTime >= 1.0 ||
            trigger != lastAwdlReceiverFeedbackTrigger else {
            return
        }

        lastAwdlReceiverFeedbackLogTime = now
        lastAwdlReceiverFeedbackTrigger = trigger
        let latestAwdlPolicy = transportController.latestAwdlMediaDecision
        let policyState = decision?.awdlPolicyState?.rawValue ?? latestAwdlPolicy?.state.rawValue ?? "observing"
        let policyTrigger = decision?.awdlPolicyTrigger?.rawValue ?? latestAwdlPolicy?.trigger.rawValue ?? "none"
        let policySelectedLever = decision?.awdlSelectedLever?.rawValue ??
            latestAwdlPolicy?.selectedLever.rawValue ??
            "observe"
        let policyTargetFPS = decision?.awdlTargetFrameRate?.description ??
            latestAwdlPolicy?.targetFrameRate.description ??
            "n/a"
        let policyScale = decision?.awdlResolutionScale ??
            latestAwdlPolicy?.resolutionScale
        let policyQualityReductionAllowed = latestAwdlPolicy?.qualityReductionAllowed == true ? "true" : "false"
        let policyPlayoutDelayMs = latestAwdlPolicy?.playoutDelayMs ?? 0
        let policyPacingBudgetBps = latestAwdlPolicy?.hostPacingBudgetBps ?? 0
        let policyPacingMbps = policyPacingBudgetBps > 0
            ? mirageFormattedMegabitRate(policyPacingBudgetBps)
            : "n/a"
        let packetTelemetry = await packetSender?.telemetrySnapshot
        let encodedOutput = await encoder?.encodedOutputSnapshot()
        let encodedWidth = Int(currentEncodedSize.width)
        let encodedHeight = Int(currentEncodedSize.height)
        let targetBitrate = currentTargetBitrateBps ?? encoderConfig.bitrate
        let targetBitrateText = targetBitrate.map { mirageFormattedMegabitRate($0) } ?? "auto"
        let actualBitrateText = encodedOutput?.actualBitrateBps.map { mirageFormattedMegabitRate($0) } ?? "n/a"
        let loomProfile = mediaSendProfileRawValue ?? "unknown"
        let loomMaxOutstandingPackets = mediaSendProfileMaxOutstandingPackets.map { "\($0)" } ?? "unknown"
        let loomMaxOutstandingBytes = mediaSendProfileMaxOutstandingBytes.map { "\($0)" } ?? "unknown"
        let loomMaxQueuedPackets = mediaSendProfileMaxQueuedPackets.map { "\($0)" } ?? "none"
        let pacing = if let decision, decision.awdlPacingDeadline > now {
            "\(Int(max(0, decision.awdlPacingDeadline - now) * 1000))ms"
        } else {
            "none"
        }
        let causes = feedback.reliabilityCauses.map(\.rawValue).joined(separator: ",")
        MirageLogger.stream(
            "AWDL host receiver feedback: stream=\(streamID) " +
                "trigger=\(trigger.rawValue) policy=\(policyState)/\(policyTrigger) " +
                "policyLever=\(policySelectedLever) " +
                "pacingHold=\(pacing) policyTargetFPS=\(policyTargetFPS) " +
                "hostFPS=\(currentFrameRate) streamScale=\(formatAwdlMetric(Double(streamScale))) " +
                "resolution=\(encodedWidth)x\(encodedHeight) " +
                "targetBitrate=\(targetBitrateText) actualBitrate=\(actualBitrateText) " +
                "quality=\(formatAwdlMetric(Double(activeQuality))) qp=n/a " +
                "qualityFloor=\(formatAwdlMetric(Double(qualityFloor))) " +
                "qualityCeiling=\(formatAwdlMetric(Double(qualityCeiling))) " +
                "policyScale=\(formatAwdlMetric(policyScale ?? 1.0)) " +
                "policyQualityCut=\(policyQualityReductionAllowed) " +
                "policyPlayoutMs=\(formatAwdlMetric(policyPlayoutDelayMs)) " +
                "policyPacing=\(policyPacingMbps) " +
                "loomProfile=\(loomProfile) " +
                "loomMaxOutstandingPackets=\(loomMaxOutstandingPackets) " +
                "loomMaxOutstandingBytes=\(loomMaxOutstandingBytes) " +
                "loomMaxQueuedPackets=\(loomMaxQueuedPackets) " +
                "senderQueueBytes=\(packetTelemetry?.queuedBytes ?? 0) " +
                "localSendStartAvgMs=\(formatAwdlMetric(packetTelemetry?.sendStartDelayAverageMs ?? 0)) " +
                "localSendStartMaxMs=\(formatAwdlMetric(packetTelemetry?.sendStartDelayMaxMs ?? 0)) " +
                "localContentProcessedAvgMs=\(formatAwdlMetric(packetTelemetry?.sendCompletionAverageMs ?? 0)) " +
                "localContentProcessedMaxMs=\(formatAwdlMetric(packetTelemetry?.sendCompletionMaxMs ?? 0)) " +
                "nonKeyframeContentProcessedMaxMs=\(formatAwdlMetric(packetTelemetry?.nonKeyframeSendCompletionMaxMs ?? 0)) " +
                "pacerFrameMaxSleepMs=\(packetTelemetry?.packetPacerFrameMaxSleepMs ?? 0) " +
                "senderLocalDeadlineDrops=\(packetTelemetry?.senderLocalDeadlineDrops ?? 0) " +
                "lateNonKeyframeSends=\(packetTelemetry?.lateNonKeyframeSends ?? 0) " +
                "senderStaleDrops=\(packetTelemetry?.stalePacketDrops ?? 0) " +
                "loomDeadlineDrops=\(packetTelemetry?.queuedUnreliableDeadlineExpiredDrops ?? 0) " +
                "loomQueueDrops=\(packetTelemetry?.queuedUnreliableQueueLimitDrops ?? 0) " +
                "loomSupersededDrops=\(packetTelemetry?.queuedUnreliableSupersededDrops ?? 0) " +
                "loomUnsupportedTransportDrops=\(packetTelemetry?.queuedUnreliableUnsupportedTransportDrops ?? 0) " +
                "loomClosedDrops=\(packetTelemetry?.queuedUnreliableClosedDrops ?? 0) " +
                "loomPendingPackets=\(packetTelemetry?.queuedUnreliablePendingPackets ?? 0) " +
                "loomOutstandingPackets=\(packetTelemetry?.queuedUnreliableOutstandingPackets ?? 0) " +
                "loomQueuedBytes=\(packetTelemetry?.queuedUnreliableQueuedBytes ?? 0) " +
                "loomPendingMax=\(packetTelemetry?.queuedUnreliablePendingPacketMax ?? 0) " +
                "loomOutstandingMax=\(packetTelemetry?.queuedUnreliableOutstandingPacketMax ?? 0) " +
                "loomQueuedBytesMax=\(packetTelemetry?.queuedUnreliableQueuedBytesMax ?? 0) " +
                "loomQueueDwellP99Ms=\(formatAwdlMetric(packetTelemetry?.queuedUnreliableQueueDwellP99Ms ?? 0)) " +
                "loomSendGapP99Ms=\(formatAwdlMetric(packetTelemetry?.queuedUnreliableSendGapP99Ms ?? 0)) " +
                "loomContentProcessedP99Ms=\(formatAwdlMetric(packetTelemetry?.queuedUnreliableContentProcessedP99Ms ?? 0)) " +
                "targetFPS=\(feedback.targetFPS) " +
                "rxFPS=\(formatAwdlMetric(feedback.receivedFPS)) " +
                "decodeFPS=\(formatAwdlMetric(feedback.decodedFPS)) " +
                "decodeSubmissions=\(feedback.inFlightDecodeSubmissions ?? 0)/\(feedback.decodeSubmissionLimit ?? 0) " +
                "presentFPS=\(formatAwdlMetric(feedback.rendererPresentedFPS)) " +
                "rxGapMaxMs=\(formatAwdlMetric(feedback.receivedWorstGapMs ?? 0)) " +
                "rxP99Ms=\(formatAwdlMetric(feedback.jitterP99Ms)) " +
                "receiverJitterP99Ms=\(formatAwdlMetric(feedback.receiverJitterP99Ms ?? 0)) " +
                "frameP95Ms=\(formatAwdlMetric(feedback.frameCompletionLatencyP95Ms ?? 0)) " +
                "keyframeP95Ms=\(formatAwdlMetric(feedback.keyframeCompletionLatencyP95Ms ?? 0)) " +
                "pFrameP50Ms=\(formatAwdlMetric(feedback.pFrameCompletionLatencyP50Ms ?? 0)) " +
                "pFrameP95Ms=\(formatAwdlMetric(feedback.pFrameCompletionLatencyP95Ms ?? 0)) " +
                "latePFrames=\(feedback.latePFrameCount ?? 0) " +
                "lostFrames=\(feedback.lostFrameCount) discardedPackets=\(feedback.discardedPacketCount) " +
                "reassemblyFrames=\(feedback.reassemblyBacklogFrames) " +
                "keyframes=\(feedback.reassemblyBacklogKeyframes) " +
                "reassemblyBytes=\(feedback.reassemblyBacklogBytes) " +
                "incompleteTimeouts=\(feedback.reassemblerIncompleteFrameTimeouts ?? 0) " +
                "missingFragments=\(feedback.reassemblerMissingFragmentTimeouts ?? 0) " +
                "fecRecovered=\(feedback.fecRecoveredFragmentCount ?? 0) " +
                "forwardGaps=\(feedback.reassemblerForwardGapTimeouts ?? 0) " +
                "playoutTargetMs=\(formatAwdlMetric(feedback.playoutDelayTargetMs ?? 0)) " +
                "playoutFrames=\(feedback.playoutDelayFrames ?? 0) " +
                "queueFrames=\(feedback.presentationQueueDepth ?? feedback.queueEstimateFrames) " +
                "targetQueueFrames=\(feedback.presentationTargetFrames ?? 0) " +
                "fillDeficitFrames=\(feedback.presentationFillDeficitFrames ?? 0) " +
                "underfillFrames=\(feedback.presentationUnderfillFrames ?? 0) " +
                "presentGapMaxMs=\(formatAwdlMetric(feedback.worstPresentationGapMs ?? 0)) " +
                "underflows=\(feedback.displayTickNoFrameCount ?? 0) " +
                "pendingNotReadyTicks=\(feedback.pendingFrameNotReadyDisplayTickCount ?? 0) " +
                "presentationStalls=\(feedback.presentationStallCount ?? 0) " +
                "recovery=\(feedback.recoveryState.rawValue) " +
                "causes=\(causes)"
        )
    }

    private func formatAwdlMetric(_ value: Double) -> String {
        String(format: "%.1f", max(0, value))
    }
}

private extension MirageMediaFeedbackRecoveryCause {
    var allowsReceiverFeedbackKeyframeRecovery: Bool {
        switch self {
        case .decodeError,
             .freezeTimeout,
             .startupTimeout,
             .manual,
             .none:
            true
        case .frameLoss,
             .memoryBudget:
            false
        }
    }
}
#endif
