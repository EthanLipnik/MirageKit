//
//  StreamContext+AdaptiveFrameCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/16/26.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    func adaptiveReceiverEvidenceState(now: CFAbsoluteTime) -> HostAdaptiveFrameCoordinator.ReceiverEvidenceState {
        guard lastReceiverFeedbackTime > 0 else { return .unknown }
        let feedbackAgeMs = max(0, (now - lastReceiverFeedbackTime) * 1_000)
        guard feedbackAgeMs <= 1_000 else { return .unknown }

        if receiverFrameBudgetLossHoldUntil > now ||
            receiverReassemblyBacklogFrames >= 8 ||
            receiverReassemblyBacklogBytes >= 4_000_000 ||
            receiverDecodeBacklogFrames >= 8 ||
            receiverPresentationBacklogFrames >= 8 ||
            (receiverAckLagMs ?? 0) >= 450 {
            return .severe
        }
        if receiverReassemblyBacklogFrames > 0 ||
            receiverReassemblyBacklogBytes > 0 ||
            receiverDecodeBacklogFrames > 0 ||
            receiverPresentationBacklogFrames > 0 ||
            (receiverAckLagMs ?? 0) >= 120 {
            return .pressured
        }
        return .healthy
    }

    func adaptiveFrameInput(
        forceKeyframe: Bool,
        isIdleFrame: Bool,
        dirtyPercentage: Float,
        sourceStill: Bool,
        inputActive: Bool,
        admitsStillQualityProbe: Bool,
        senderQueuedBytes: Int,
        now: CFAbsoluteTime
    ) -> HostAdaptiveFrameCoordinator.FrameInput {
        HostAdaptiveFrameCoordinator.FrameInput(
            forceKeyframe: forceKeyframe,
            hasSentKeyframe: lastSuccessfulKeyframeSendTime > 0 || lastKeyframeTime > 0,
            pendingKeyframeReason: pendingKeyframeReason,
            frameChainRepairActive: frameChainSuppressesPFrames,
            isIdleFrame: isIdleFrame,
            dirtyPercentage: dirtyPercentage,
            sourceStill: sourceStill,
            inputActive: inputActive,
            admitsStillQualityProbe: admitsStillQualityProbe,
            senderQueuedBytes: senderQueuedBytes,
            queuePressureBytes: queuePressureBytes,
            maxQueuedBytes: maxQueuedBytes,
            receiverState: adaptiveReceiverEvidenceState(now: now),
            currentQuality: activeQuality,
            qualityFloor: adaptiveFrameDecisionQualityFloor(
                sourceStill: sourceStill,
                admitsStillQualityProbe: admitsStillQualityProbe
            ),
            qualityCeiling: adaptiveFrameDecisionQualityCeiling(),
            mediaPathProfile: mediaPathProfile,
            now: now
        )
    }

    private func adaptiveFrameDecisionQualityCeiling() -> Float {
        let runtimeCeiling = max(qualityCeiling, steadyQualityCeiling)
        guard !mediaPathProfile.usesAwdlRadioPolicy else { return runtimeCeiling }
        return min(compressionQualityCeiling, max(runtimeCeiling, configuredQualityCeiling))
    }

    func adaptiveTransportPressureSnapshot(
        senderTelemetry: StreamPacketSender.TelemetrySnapshot?,
        now: CFAbsoluteTime
    ) -> HostAdaptiveFrameCoordinator.TransportPressureSnapshot {
        let captureCadence = HostAdaptiveFrameCoordinator.classifyCaptureCadence(
            lastCaptureCadenceMetrics,
            targetFrameRate: currentFrameRate
        )
        return HostAdaptiveFrameCoordinator.TransportPressureSnapshot(
            mediaPathProfile: mediaPathProfile,
            currentFrameRate: currentFrameRate,
            captureCadenceState: captureCadence.state,
            captureCadenceSummary: captureCadence.summary,
            receiverState: adaptiveReceiverEvidenceState(now: now),
            receiverCapacityLearningQuarantineReason: receiverFrameBudgetCapacityLearningQuarantineReason(now: now),
            receiverReassemblyBacklogFrames: receiverReassemblyBacklogFrames,
            receiverReassemblyBacklogBytes: receiverReassemblyBacklogBytes,
            receiverDecodeBacklogFrames: receiverDecodeBacklogFrames,
            receiverPresentationBacklogFrames: receiverPresentationBacklogFrames,
            receiverLossHoldActive: receiverFrameBudgetLossHoldUntil > now,
            receiverAckLagMs: receiverAckLagMs,
            senderQueuedBytes: senderTelemetry?.queuedBytes ?? packetSender?.queuedByteCount ?? 0,
            queuePressureBytes: queuePressureBytes,
            maxQueuedBytes: maxQueuedBytes,
            senderDropHoldActive: senderFrameBudgetDropHoldUntil > now,
            unstartedPFrameCount: senderTelemetry?.unstartedPFrameCount ?? 0,
            oldestUnstartedPFrameAgeMs: senderTelemetry?.oldestUnstartedPFrameAgeMs ?? 0,
            oldestUnstartedPFrameLatenessMs: senderTelemetry?.oldestUnstartedPFrameLatenessMs ?? 0,
            queuedUnreliablePendingPackets: senderTelemetry?.queuedUnreliablePendingPackets ?? 0,
            queuedUnreliableOutstandingPackets: senderTelemetry?.queuedUnreliableOutstandingPackets ?? 0,
            queuedUnreliableQueuedBytes: senderTelemetry?.queuedUnreliableQueuedBytes ?? 0,
            queuedUnreliableQueueDwellP99Ms: senderTelemetry?.queuedUnreliableQueueDwellP99Ms ?? 0,
            queuedUnreliableSendGapP99Ms: senderTelemetry?.queuedUnreliableSendGapP99Ms ?? 0,
            queuedUnreliableContentProcessedP99Ms: senderTelemetry?.queuedUnreliableContentProcessedP99Ms ?? 0,
            packetPacerFrameMaxSleepMs: Double(senderTelemetry?.packetPacerFrameMaxSleepMs ?? 0),
            startupProtectionActive: isStartupTransportProtectionActive(now: now),
            frameChainRepairActive: frameChainState != .normal || frameChainSuppressesPFrames,
            realtimePressureState: realtimePressureState,
            realtimePressureReason: realtimePressureReason,
            transportAdmissionActiveDuration: transportAdmissionPressureState.activeDuration(now: now)
        )
    }

    func adaptiveTransportPressureIsActionable(
        senderTelemetry: StreamPacketSender.TelemetrySnapshot?,
        now: CFAbsoluteTime
    ) -> Bool {
        adaptiveFrameCoordinator.transportPressureIsActionable(
            adaptiveTransportPressureSnapshot(senderTelemetry: senderTelemetry, now: now)
        )
    }

    func evaluateAdaptiveFrameAdmission(
        forceKeyframe: Bool,
        isIdleFrame: Bool,
        dirtyPercentage: Float,
        sourceStill: Bool,
        inputActive: Bool,
        admitsStillQualityProbe: Bool,
        senderQueuedBytes: Int,
        now: CFAbsoluteTime
    ) -> HostAdaptiveFrameCoordinator.FrameDecision {
        let input = adaptiveFrameInput(
            forceKeyframe: forceKeyframe,
            isIdleFrame: isIdleFrame,
            dirtyPercentage: dirtyPercentage,
            sourceStill: sourceStill,
            inputActive: inputActive,
            admitsStillQualityProbe: admitsStillQualityProbe,
            senderQueuedBytes: senderQueuedBytes,
            now: now
        )
        let decision = adaptiveFrameCoordinator.evaluateFrame(input)
        logAdaptiveFrameDecisionIfNeeded(decision, input: input, now: now)
        return decision
    }

    func applyAdaptiveFrameDecisionQualityIfNeeded(
        _ decision: HostAdaptiveFrameCoordinator.FrameDecision
    ) async {
        guard runtimeQualityAdjustmentEnabled,
              encoderConfig.codec != .proRes4444,
              decision.action == .encodePFrame,
              let targetQuality = decision.targetQuality else {
            return
        }
        guard streamQualityGovernor.allowsFrameIntentQualityWrite(
            targetQuality: targetQuality,
            currentQuality: activeQuality,
            contract: currentStreamQualityContract(),
            now: CFAbsoluteTimeGetCurrent()
        ) else {
            return
        }

        let visualCeiling: Float
        if mediaPathProfile.usesAwdlRadioPolicy {
            visualCeiling = qualityCeiling
        } else if mediaPathProfile.usesLocalBulkTransportPolicy,
                  decision.intent == .realtimeMotion {
            visualCeiling = min(
                compressionQualityCeiling,
                max(qualityCeiling, targetQuality)
            )
        } else {
            visualCeiling = min(
                compressionQualityCeiling,
                max(qualityCeiling, configuredQualityCeiling, steadyQualityCeiling, targetQuality)
            )
        }
        guard visualCeiling > 0 else { return }

        let previousQualityCeiling = qualityCeiling
        let previousQualityFloor = qualityFloor
        if !mediaPathProfile.usesAwdlRadioPolicy,
           visualCeiling > qualityCeiling {
            qualityCeiling = visualCeiling
            qualityFloor = resolvedRuntimeQualityFloor(for: qualityCeiling)
            keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(for: qualityCeiling)
        }

        let previousQuality = activeQuality
        let decisionFloor = adaptiveFrameDecisionQualityFloor(
            sourceStill: decision.intent != .realtimeMotion,
            admitsStillQualityProbe: decision.intent == .clarityRefresh
        )
        let boundedTarget = max(min(qualityFloor, decisionFloor), min(visualCeiling, targetQuality))
        guard abs(Double(boundedTarget - activeQuality)) > 0.0001 else { return }
        activeQuality = boundedTarget
        await encoder?.updateQuality(activeQuality)

        MirageLogger.metrics(
            "event=adaptive_frame_quality stream=\(streamID) " +
                "intent=\(decision.intent.rawValue) lane=\(decision.lane.rawValue) " +
                "active=\(previousQuality.formatted(.number.precision(.fractionLength(2))))" +
                "->\(activeQuality.formatted(.number.precision(.fractionLength(2)))) " +
                "ceiling=\(previousQualityCeiling.formatted(.number.precision(.fractionLength(2))))" +
                "->\(qualityCeiling.formatted(.number.precision(.fractionLength(2)))) " +
                "floor=\(previousQualityFloor.formatted(.number.precision(.fractionLength(2))))" +
                "->\(qualityFloor.formatted(.number.precision(.fractionLength(2)))) " +
                "reason=\(decision.reason)"
        )
    }

    func applyAdaptiveRuntimeDecision(
        _ decision: HostFrameBudgetDecision,
        now: CFAbsoluteTime,
        allowsLocalBulkReductionOverride: Bool = false
    ) async {
        let controllerRuntimeCeilingBps = adaptivePFrameController.runtimeCeilingBps
        guard runtimeQualityAdjustmentEnabled else {
            realtimePressureState = decision.state
            realtimePressureReason = decision.reason.rawValue
            realtimeRuntimeBitrateCeilingBps = controllerRuntimeCeilingBps
            await applyAwdlManualQualityRuntimeSafety(decision)
            logAdaptiveRuntimeDecisionIfNeeded(now: now, decision: decision)
            return
        }

        let senderTelemetry = await packetSender?.telemetrySnapshot
        let pressureSnapshot = adaptiveTransportPressureSnapshot(
            senderTelemetry: senderTelemetry,
            now: now
        )
        let localMotionReductionOverride = allowsLocalBulkReductionOverride ||
            allowsLocalMotionRuntimeReductionOverride(for: decision.reason)
        let governedDecision = streamQualityGovernor.evaluateRuntimeDecision(
            decision,
            snapshot: pressureSnapshot,
            contract: currentStreamQualityContract(),
            currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            allowsLocalBulkReductionOverride: localMotionReductionOverride,
            now: now
        )

        guard let decision = governedDecision.decision else {
            if realtimePressureState != .recovery {
                realtimePressureState = .observing
                realtimePressureReason = governedDecision.streamDecision.blockedLeverReason ?? "governor-observe"
            }
            realtimeRuntimeBitrateCeilingBps = nil
            realtimeRuntimeQualityCeiling = nil
            logAdaptiveRuntimeDecisionObserveOnly(decision, now: now)
            return
        }

        realtimePressureState = decision.state
        realtimePressureReason = decision.reason.rawValue
        let runtimeCeilingBps = max(controllerRuntimeCeilingBps ?? decision.targetBitrateBps, decision.targetBitrateBps)
        realtimeRuntimeBitrateCeilingBps = runtimeCeilingBps
        realtimeRuntimeQualityCeiling = decision.state == .observing ? nil : decision.qualityCeiling

        let appliesGradualHealthyFrameBudget = decision.state == .observing && decision.reason == .healthy
        let currentBudgetBitrate = currentTargetBitrateBps ?? encoderConfig.bitrate ?? decision.targetBitrateBps
        let currentEncoderRateHint = realtimeEncoderRateHintBps ?? encoderConfig.bitrate ?? currentBudgetBitrate
        let currentSenderPacingBitrate = realtimeSenderPacingBitrateBps ?? currentBudgetBitrate
        let decisionSenderPacingBitrate = adaptiveRuntimeSenderPacingBitrate(for: decision)
        let appliedTargetBitrate = appliesGradualHealthyFrameBudget
            ? max(decision.targetBitrateBps, currentBudgetBitrate)
            : decision.targetBitrateBps
        let appliedEncoderRateHint = appliesGradualHealthyFrameBudget
            ? max(decision.targetBitrateBps, currentEncoderRateHint, appliedTargetBitrate)
            : decision.targetBitrateBps
        let appliedSenderPacingBitrate = appliesGradualHealthyFrameBudget
            ? max(decisionSenderPacingBitrate, currentSenderPacingBitrate, appliedTargetBitrate)
            : decisionSenderPacingBitrate
        let appliedRuntimeBitrateCeiling: Int?
        if appliesGradualHealthyFrameBudget {
            appliedRuntimeBitrateCeiling = max(
                runtimeCeilingBps,
                appliedTargetBitrate,
                appliedEncoderRateHint,
                appliedSenderPacingBitrate
            )
        } else {
            appliedRuntimeBitrateCeiling = runtimeCeilingBps
        }

        realtimeRuntimeBitrateCeilingBps = appliedRuntimeBitrateCeiling
        await applyRealtimeBudgetBitrate(
            appliedTargetBitrate,
            ceilingBitrateBps: appliedRuntimeBitrateCeiling,
            encoderRateHintBps: appliedEncoderRateHint,
            senderPacingBitrateBps: appliedSenderPacingBitrate,
            reason: decision.reason.rawValue,
            allowsActiveQualityRaise: appliesGradualHealthyFrameBudget ? true : nil,
            clearsRuntimeQualityCeiling: appliesGradualHealthyFrameBudget ? true : nil,
            allowsFrameBudgetRaise: appliesGradualHealthyFrameBudget ? true : nil
        )

        let qualityChanged = await applyAdaptiveRuntimeQuality(decision)
        if qualityChanged {
            queueStillQualityRefreshKeyframeIfNeeded(decision: decision, now: now)
        }

        logAdaptiveRuntimeDecisionIfNeeded(now: now, decision: decision)
    }

    private func logAdaptiveRuntimeDecisionObserveOnly(
        _ decision: HostFrameBudgetDecision,
        now: CFAbsoluteTime
    ) {
        guard now - receiverFrameBudgetObserveOnlyLastLogTime >= 0.5 else { return }
        receiverFrameBudgetObserveOnlyLastLogTime = now
        MirageLogger.metrics(
            "event=adaptive_runtime_observe_only stream=\(streamID) " +
                "state=\(decision.state.rawValue) reason=\(decision.reason.rawValue) " +
                "target=\(decision.targetBitrateBps) quality=\(decision.quality)"
        )
    }

    private func applyAwdlManualQualityRuntimeSafety(_ decision: HostFrameBudgetDecision) async {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return }
        realtimeRuntimeQualityCeiling = nil
        let pacingBitrate = adaptiveRuntimeSenderPacingBitrate(for: decision)
        guard pacingBitrate > 0,
              pacingBitrate != realtimeSenderPacingBitrateBps else {
            return
        }
        realtimeSenderPacingBitrateBps = pacingBitrate
        await packetSender?.setTargetBitrateBps(pacingBitrate)
        MirageLogger.metrics(
            "AWDL manual-quality adaptive runtime safety for stream \(streamID): " +
                "senderPacing=\(mirageFormattedMegabitRate(pacingBitrate)) " +
                "state=\(decision.state.rawValue) reason=\(decision.reason.rawValue)"
        )
    }

    private func adaptiveRuntimeSenderPacingBitrate(for decision: HostFrameBudgetDecision) -> Int {
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

    private func applyAdaptiveRuntimeQuality(_ decision: HostFrameBudgetDecision) async -> Bool {
        let previousQuality = activeQuality
        let proposedQualityCeiling: Float
        if decision.state == .observing {
            proposedQualityCeiling = if decision.reason == .healthy,
                                        !mediaPathProfile.usesAwdlRadioPolicy {
                min(resolvedQualityCeiling, max(qualityCeiling, configuredQualityCeiling, steadyQualityCeiling))
            } else {
                min(resolvedQualityCeiling, steadyQualityCeiling)
            }
        } else {
            proposedQualityCeiling = min(resolvedQualityCeiling, decision.qualityCeiling, steadyQualityCeiling)
        }
        let governorQualityFloor = adaptiveRuntimeQualityFloor(for: decision)
        qualityCeiling = min(
            resolvedQualityCeiling,
            max(
                resolvedRuntimeQualityCeiling(for: proposedQualityCeiling),
                governorQualityFloor
            )
        )
        let proposedKeyframeQualityCeiling = min(decision.keyframeQuality, qualityCeiling)
        let keyframeQualityCeiling = resolvedRuntimeKeyframeQualityCeiling(for: proposedKeyframeQualityCeiling)
        qualityFloor = min(
            qualityCeiling,
            max(resolvedRuntimeQualityFloor(for: qualityCeiling), governorQualityFloor)
        )
        keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(
            for: keyframeQualityCeiling
        )
        let decisionQuality = max(qualityFloor, min(qualityCeiling, decision.quality))
        activeQuality = if decision.state == .observing {
            if decision.reason == .healthy {
                max(min(previousQuality, qualityCeiling), decisionQuality)
            } else if decision.reason == .motionOnset {
                decisionQuality
            } else {
                max(min(previousQuality, qualityCeiling), decisionQuality)
            }
        } else {
            decisionQuality
        }
        guard abs(Double(activeQuality - previousQuality)) > 0.0001 else { return false }
        await encoder?.updateQuality(activeQuality)
        MirageLogger.metrics(
            "Adaptive runtime updated quality for stream \(streamID): " +
                "active=\(formatAdaptiveMetric(Double(activeQuality))) " +
                "ceiling=\(formatAdaptiveMetric(Double(qualityCeiling))) reason=\(decision.reason.rawValue)"
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

    private func logAdaptiveRuntimeDecisionIfNeeded(
        now: CFAbsoluteTime,
        decision: HostFrameBudgetDecision
    ) {
        guard realtimeLastLoggedState != decision.state ||
            realtimeLastLoggedBitrateCeilingBps != realtimeRuntimeBitrateCeilingBps ||
            now - realtimeLastLogTime >= 2.0 else {
            return
        }
        let stateChanged = realtimeLastLoggedState != decision.state
        realtimeLastLogTime = now
        realtimeLastLoggedState = decision.state
        realtimeLastLoggedBitrateCeilingBps = realtimeRuntimeBitrateCeilingBps
        if stateChanged {
            let transitionBitrateText = (currentTargetBitrateBps ?? encoderConfig.bitrate)
                .map { mirageFormattedMegabitRate($0) } ?? "auto"
            MirageLogger.stream(
                "Adaptive runtime state=\(decision.state.rawValue) reason=\(decision.reason.rawValue) " +
                    "stream=\(streamID) target=\(mirageFormattedMegabitRate(decision.targetBitrateBps)) " +
                    "current=\(transitionBitrateText) " +
                    "quality=\(formatAdaptiveMetric(Double(decision.quality)))"
            )
        }

        let ceilingText = realtimeRuntimeBitrateCeilingBps
            .map { mirageFormattedMegabitRate($0) }
            ?? "unknown"
        let currentBitrateText = (currentTargetBitrateBps ?? encoderConfig.bitrate)
            .map { mirageFormattedMegabitRate($0) }
            ?? "auto"
        let qualityText = realtimeRuntimeQualityCeiling
            .map { formatAdaptiveMetric(Double($0)) }
            ?? "none"
        let cleanPFrameText = adaptivePFrameController.recentCleanPFrameBaselineWireBytes
            .map { "\($0)B" }
            ?? "none"
        MirageLogger.metrics(
            "Adaptive runtime: stream=\(streamID) " +
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

    private func formatAdaptiveMetric(_ value: Double) -> String {
        String(format: "%.1f", max(0, value))
    }

    func logAdaptiveFrameDecisionIfNeeded(
        _ decision: HostAdaptiveFrameCoordinator.FrameDecision,
        input: HostAdaptiveFrameCoordinator.FrameInput,
        now: CFAbsoluteTime
    ) {
        guard adaptiveFrameCoordinator.shouldLogDecision(decision, now: now) else { return }
        let qualityText = decision.targetQuality
            .map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "none"
        let barrierText = adaptiveFrameCoordinator.activeKeyframeBarrierKind?.rawValue ?? "none"
        MirageLogger.metrics(
            "event=adaptive_frame_decision stream=\(streamID) " +
                "intent=\(decision.intent.rawValue) action=\(decision.action.rawValue) " +
                "lane=\(decision.lane.rawValue) deadline=\(decision.deadlineClass.rawValue) " +
                "quality=\(qualityText) senderQueue=\(input.senderQueuedBytes) " +
                "receiver=\(input.receiverState.rawValue) barrier=\(barrierText) reason=\(decision.reason)"
        )
    }

    func releaseAdaptiveKeyframeBarrier(
        _ release: HostAdaptiveFrameCoordinator.KeyframeBarrierRelease
    ) {
        suppressEncodedNonKeyframesUntilKeyframe = false
        pendingEmergencyKeyframeQuality = nil
        senderDeadlineRecoveryQualityCeiling = nil
        if release.kind == .bootstrap {
            pendingReceiverAcceptedKeyframeReason = nil
            pendingReceiverAcceptedKeyframeFrameNumber = nil
        }
        MirageLogger.metrics(
            "event=adaptive_keyframe_barrier stream=\(streamID) action=release " +
                "kind=\(release.kind.rawValue) evidence=\(release.evidence) " +
                "suppressedPFrames=\(release.suppressedPFrameCount) reason=\(release.reason)"
        )
        scheduleProcessingIfNeeded()
    }

    func releaseStartupBarrierIfReady(now: CFAbsoluteTime) {
        let senderQueuedBytes = packetSender?.queuedByteCount ?? 0
        guard let release = adaptiveFrameCoordinator.releaseStartupBarrierIfTimedOut(
            senderQueuedBytes: senderQueuedBytes,
            queuePressureBytes: queuePressureBytes,
            now: now
        ) else {
            return
        }
        releaseAdaptiveKeyframeBarrier(release)
    }
}
#endif
