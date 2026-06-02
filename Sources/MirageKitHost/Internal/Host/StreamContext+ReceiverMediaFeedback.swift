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
extension StreamContext {
    func applyReceiverMediaFeedback(_ feedback: ReceiverMediaFeedbackMessage) async {
        let now = CFAbsoluteTimeGetCurrent()
        lastReceiverFeedbackTime = now
        receiverReassemblyBacklogFrames = feedback.reassemblyBacklogFrames
        receiverReassemblyBacklogBytes = feedback.reassemblyBacklogBytes
        receiverDecodeBacklogFrames = feedback.decodeQueueDepth ?? feedback.decodeBacklogFrames
        receiverPresentationBacklogFrames = feedback.presentationQueueDepth ?? feedback.presentationBacklogFrames
        receiverLatestAcceptedFrameNumber = feedback.latestAcceptedFrameNumber
        receiverLatestPresentedFrameNumber = feedback.latestPresentedFrameNumber
        receiverLatestPresentedFrameAgeMs = feedback.latestPresentedFrameAgeMs
        receiverLostFrameCount = feedback.lostFrameCount
        receiverDiscardedPacketCount = feedback.discardedPacketCount
        latestReceiverRecoveryCause = feedback.recoveryCause
        updateReceiverCapacityLearningQuarantine(feedback, now: now)
        let ackFrameBudgetDecision = applyReceiverFrameAcknowledgements(feedback.ackRanges, now: now)
        let pFrameTimingDecision = applyReceiverPFrameTimingSamples(feedback.pFrameTimingSamples, now: now)
        let transportDecision = transportController.update(
            with: feedback,
            currentFrameRate: currentFrameRate,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile,
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
        if let frameBudgetDecision {
            await applyFrameBudgetDecision(frameBudgetDecision, now: now)
        }
        if let ackFrameBudgetDecision {
            await applyFrameBudgetDecision(ackFrameBudgetDecision, now: now)
        }
        if let pFrameTimingDecision {
            await applyFrameBudgetDecision(pFrameTimingDecision, now: now)
        }
        noteReceiverAcceptedKeyframeIfNeeded(feedback, now: now)
        noteReceiverPresentationRecoveryEvidenceIfNeeded(feedback, now: now)
        scheduleStillQualityProbeIfNeeded(now: now, reason: "receiver-feedback")
        await scheduleReceiverFeedbackKeyframeRecoveryIfNeeded(feedback, now: now)
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
        guard pendingKeyframeReason == nil,
              now >= keyframeSendDeadline,
              !isKeyframeEncoding,
              frameChainRepairKeyframeRetryTask == nil else {
            return
        }
        if case .emergencyKeyframePending = frameChainState {
            return
        }

        let bypassesCooldown = recoveryCauseBypassesAdaptiveKeyframeCooldown(feedback.recoveryCause) ||
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
            feedback.reliabilityCauses.contains(.noProgressTimeout) ||
            feedback.reliabilityCauses.contains(.keyframeStarvation)
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
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision? {
        guard runtimeQualityAdjustmentEnabled, !samples.isEmpty else { return nil }
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
        return latestDecision
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
        guard runtimeQualityAdjustmentEnabled else { return }
        realtimePressureState = decision.state
        realtimePressureReason = decision.reason.rawValue
        realtimeRuntimeBitrateCeilingBps = adaptivePFrameController.runtimeCeilingBps
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

    private func realtimeSenderPacingBitrate(for decision: HostFrameBudgetDecision) -> Int {
        decision.targetBitrateBps
    }

    private func applyFrameBudgetQuality(_ decision: HostFrameBudgetDecision) async -> Bool {
        let previousQuality = activeQuality
        if decision.state == .observing {
            qualityCeiling = min(resolvedQualityCeiling, steadyQualityCeiling)
        } else {
            qualityCeiling = min(resolvedQualityCeiling, decision.qualityCeiling, steadyQualityCeiling)
        }
        qualityFloor = resolvedRuntimeQualityFloor(for: qualityCeiling)
        keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(
            for: min(decision.keyframeQuality, qualityCeiling)
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
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        let trigger = decision?.awdlPacingTrigger ?? decision?.pressureTrigger ?? .none
        let hasReceiverStress = trigger != .none ||
            feedback.recoveryState != .idle ||
            feedback.lostFrameCount > 0 ||
            feedback.discardedPacketCount > 0 ||
            feedback.reassemblyBacklogFrames > 0 ||
            feedback.reassemblyBacklogKeyframes > 0 ||
            (feedback.presentationStallCount ?? 0) > 0 ||
            (feedback.displayTickNoFrameCount ?? 0) > 0 ||
            (feedback.reassemblerForwardGapTimeouts ?? 0) > 0
        guard hasReceiverStress ||
            lastAwdlReceiverFeedbackLogTime == 0 ||
            now - lastAwdlReceiverFeedbackLogTime >= 5.0 ||
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
        let policyTargetFPS = decision?.awdlTargetFrameRate?.description ??
            latestAwdlPolicy?.targetFrameRate.description ??
            "n/a"
        let packetTelemetry = await packetSender?.telemetrySnapshot
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
        MirageLogger.metrics(
            "AWDL host receiver feedback: stream=\(streamID) " +
                "trigger=\(trigger.rawValue) policy=\(policyState)/\(policyTrigger) " +
                "pacingHold=\(pacing) policyTargetFPS=\(policyTargetFPS) " +
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
                "targetFPS=\(feedback.targetFPS) " +
                "rxFPS=\(formatAwdlMetric(feedback.receivedFPS)) " +
                "decodeFPS=\(formatAwdlMetric(feedback.decodedFPS)) " +
                "presentFPS=\(formatAwdlMetric(feedback.rendererPresentedFPS)) " +
                "rxGapMaxMs=\(formatAwdlMetric(feedback.receivedWorstGapMs ?? 0)) " +
                "rxP99Ms=\(formatAwdlMetric(feedback.jitterP99Ms)) " +
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
                "presentGapMaxMs=\(formatAwdlMetric(feedback.worstPresentationGapMs ?? 0)) " +
                "underflows=\(feedback.displayTickNoFrameCount ?? 0) " +
                "presentationStalls=\(feedback.presentationStallCount ?? 0) " +
                "recovery=\(feedback.recoveryState.rawValue) " +
                "causes=\(causes)"
        )
    }

    private func formatAwdlMetric(_ value: Double) -> String {
        String(format: "%.1f", max(0, value))
    }
}
#endif
