//
//  StreamContext+Processing+Quality.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Pipeline metrics, in-flight depth, and runtime quality adjustment.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    /// Logs periodic stream pipeline metrics and updates adaptive in-flight depth.
    func logPipelineStatsIfNeeded() async {
        let now = CFAbsoluteTimeGetCurrent()
        guard lastPipelineStatsLogTime > 0 else {
            lastPipelineStatsLogTime = now
            return
        }
        let elapsed = now - lastPipelineStatsLogTime
        guard elapsed >= pipelineStatsInterval else { return }

        let metricsEnabled = MirageSteadyStateDiagnostics.isEnabled && MirageLogger.isEnabled(.metrics)
        let captureIngressFPS = Double(captureIngressIntervalCount) / elapsed
        let captureFPS = Double(captureIntervalCount) / elapsed
        let encodeAttemptFPS = Double(encodeAttemptIntervalCount) / elapsed
        let encodeFPS = Double(encodeAcceptedIntervalCount) / elapsed
        lastCaptureIngressFPS = captureIngressFPS
        lastCaptureFPS = captureFPS
        lastEncodeAttemptFPS = encodeAttemptFPS
        let encodeAvgMs = await encoder?.averageEncodeTimeMs ?? 0
        let pendingCount = frameInbox.pendingCount
        if metricsEnabled {
            let queueBytes = packetSender?.queuedByteCount ?? 0
            let captureGapMs = lastCapturedFrameTime > 0
                ? (now - lastCapturedFrameTime) * 1000
                : 0
            let syntheticFPS = Double(syntheticIntervalCount) / elapsed
            let ingressText = captureIngressFPS.formatted(.number.precision(.fractionLength(1)))
            let captureText = captureFPS.formatted(.number.precision(.fractionLength(1)))
            let attemptText = encodeAttemptFPS.formatted(.number.precision(.fractionLength(1)))
            let encodeText = encodeFPS.formatted(.number.precision(.fractionLength(1)))
            let encodeAvgText = encodeAvgMs.formatted(.number.precision(.fractionLength(1)))
            let queueKB = Self.roundedKilobytes(queueBytes)
            let captureGapText = captureGapMs.formatted(.number.precision(.fractionLength(1)))
            let syntheticText = syntheticFPS.formatted(.number.precision(.fractionLength(1)))

            let callbackFailures = encoder?.consumeCallbackFailureCount() ?? 0

            MirageLogger.metrics(
                "Pipeline: ingress=\(ingressText)fps capture=\(captureText)fps drop=\(captureDroppedIntervalCount) " +
                    "bp=\(backpressureDropIntervalCount) encode=\(encodeText)fps attempt=\(attemptText)fps reject=\(encodeRejectedIntervalCount) " +
                    "skip(qFull=\(encodeSkipQueueFullIntervalCount) dim=\(encodeSkipDimensionIntervalCount) inactive=\(encodeSkipInactiveIntervalCount) " +
                    "session=\(encodeSkipNoSessionIntervalCount)) error=\(encodeErrorIntervalCount) cbFail=\(callbackFailures) " +
                    "synthetic=\(syntheticText)fps gap=\(captureGapText)ms inFlight=\(inFlightCount) buffer=\(pendingCount)/\(frameBufferDepth) " +
                    "queue=\(queueKB)KB encodeAvg=\(encodeAvgText)ms"
            )
        }

        await updateInFlightLimitIfNeeded(
            averageEncodeMs: encodeAvgMs,
            pendingCount: pendingCount,
            at: now
        )
        resetPipelineStatsWindow()
        lastPipelineStatsLogTime = now
    }

    /// Clears per-interval pipeline counters after a metrics sample is emitted.
    func resetPipelineStatsWindow() {
        captureIngressIntervalCount = 0
        captureIntervalCount = 0
        captureDroppedIntervalCount = 0
        encodeAttemptIntervalCount = 0
        encodeAcceptedIntervalCount = 0
        encodeRejectedIntervalCount = 0
        encodeErrorIntervalCount = 0
        backpressureDropIntervalCount = 0
        encodeSkipQueueFullIntervalCount = 0
        encodeSkipDimensionIntervalCount = 0
        encodeSkipInactiveIntervalCount = 0
        encodeSkipNoSessionIntervalCount = 0
        syntheticIntervalCount = 0
    }

    /// Adjusts encoder concurrency to balance latency and encode budget pressure.
    func updateInFlightLimitIfNeeded(
        averageEncodeMs: Double,
        pendingCount: Int,
        at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    )
    async {
        guard maxInFlightFramesCap > 1 else { return }
        if useLowLatencyPipeline {
            let baselineLowLatencyLimit = Self.lowLatencyPipelineInFlightLimit(
                streamKind: streamKind,
                frameRate: currentFrameRate,
                latencyMode: latencyMode,
                hostBufferingPolicy: hostBufferingPolicy
            )
            let lowLatencyLimit = min(maxInFlightFramesCap, max(1, baselineLowLatencyLimit))
            if maxInFlightFrames != lowLatencyLimit {
                maxInFlightFrames = lowLatencyLimit
                await encoder?.updateInFlightLimit(lowLatencyLimit)
                MirageLogger.metrics(
                    "In-flight depth forced to \(lowLatencyLimit) (low latency pipeline)"
                )
            }
            return
        }

        if lastInFlightAdjustmentTime > 0, now - lastInFlightAdjustmentTime < inFlightAdjustmentCooldown { return }

        let cadenceTarget = MirageStreamCadenceTarget(
            sourceFPS: currentFrameRate,
            displayFPS: currentFrameRate,
            latencyMode: latencyMode
        )
        let frameBudgetMs = cadenceTarget.sourceFrameBudgetMs
        var desired = maxInFlightFrames

        let smoothnessFirstMode = latencyMode == .smoothest
        let increaseThreshold = smoothnessFirstMode ? 1.02 : 1.10
        let decreaseThreshold = smoothnessFirstMode ? 0.90 : 0.80
        if averageEncodeMs > frameBudgetMs * increaseThreshold || pendingCount > 0 {
            desired = min(maxInFlightFrames + 1, maxInFlightFramesCap)
        } else if averageEncodeMs < frameBudgetMs * decreaseThreshold, pendingCount == 0 {
            desired = max(maxInFlightFrames - 1, minInFlightFrames)
        }

        if desired < minInFlightFrames { desired = minInFlightFrames }

        guard desired != maxInFlightFrames else { return }
        maxInFlightFrames = desired
        lastInFlightAdjustmentTime = now
        await encoder?.updateInFlightLimit(desired)
        let budgetText = frameBudgetMs.formatted(.number.precision(.fractionLength(1)))
        let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.metrics("In-flight depth set to \(desired) (encode \(avgText)ms, budget \(budgetText)ms)")
    }

    func evaluateEncodedFrameBudget(
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        isKeyframe: Bool,
        encodedAt now: CFAbsoluteTime
    ) async -> HostEncodedFrameAdmissionDecision {
        guard runtimeQualityAdjustmentEnabled, byteCount > 0 else {
            return HostEncodedFrameAdmissionDecision(
                admission: .send,
                budgetDecision: nil,
                sendDeadline: now + 1.0 / Double(max(1, currentFrameRate)),
                byteRatio: 0,
                wireRatio: 0,
                packetRatio: 0
            )
        }
        let decision = adaptivePFrameController.evaluateEncodedFrame(
            byteCount: byteCount,
            wireBytes: wireBytes,
            packetCount: packetCount,
            isKeyframe: isKeyframe,
            isRecoveryKeyframe: isKeyframe && keyframeUsesEmergencyBudget,
            adaptiveKeyframeAllowed: !isRecoveryKeyframeCooldownActive(now: now),
            receiverHealthy: receiverFrameBudgetIsHealthy(now: now),
            senderHealthy: await senderFrameBudgetIsHealthy(now: now),
            currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            requestedTargetBitrateBps: requestedTargetBitrate,
            startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
            minimumBitrateFloorBps: realtimeMinimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: activeQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            now: now
        )
        if !isKeyframe, let budgetDecision = decision.budgetDecision {
            await applyFrameBudgetDecision(budgetDecision, now: now)
        }
        return decision
    }

    private var keyframeUsesEmergencyBudget: Bool {
        pendingEmergencyKeyframeQuality != nil || frameChainState != .normal
    }

    func handleDroppedPFrameForTransportBudget(
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        evaluation: HostEncodedFrameAdmissionDecision,
        encodedAt now: CFAbsoluteTime
    ) async {
        droppedFrameCount += 1
        startFrameChainRepair(
            reason: "transport-p-frame-over-budget",
            now: now
        )
        await noteEmergencyKeyframePrepared(using: evaluation.budgetDecision)
        await scheduleEmergencyChainRepairKeyframe(
            reason: "Transport P-frame chain repair",
            bypassesRecoveryCooldown: false,
            now: now
        )
        logAdaptivePFrameAdmissionIfNeeded(
            frameNumber: nil,
            byteCount: byteCount,
            wireBytes: wireBytes,
            packetCount: packetCount,
            evaluation: evaluation,
            action: "drop-chain-repair",
            now: now
        )
    }

    func handleDroppedRecoveryKeyframeForTransportBudget(
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        evaluation: HostEncodedFrameAdmissionDecision,
        encodedAt now: CFAbsoluteTime
    ) async {
        droppedFrameCount += 1
        await noteEmergencyKeyframePrepared(using: evaluation.budgetDecision)
        let didLowerScale = await advanceEmergencyRecoveryScaleIfPossible(
            reason: "adaptive-repair-keyframe-over-budget",
            now: now
        )
        scheduleFrameChainRepairKeyframeRetry(
            reason: didLowerScale
                ? "Adaptive repair keyframe retry after scale change"
                : "Adaptive repair keyframe over budget",
            bypassesRecoveryCooldown: latestReceiverRecoveryCause == .decodeError
        )
        logAdaptivePFrameAdmissionIfNeeded(
            frameNumber: nil,
            byteCount: byteCount,
            wireBytes: wireBytes,
            packetCount: packetCount,
            evaluation: evaluation,
            action: "drop-keyframe-retry",
            now: now
        )
    }

    private func encodedFrameBudgetBytes() -> Double? {
        let targetBitrate = realtimeRuntimeBitrateCeilingBps ??
            currentTargetBitrateBps ??
            encoderConfig.bitrate ??
            requestedTargetBitrate ??
            startupBitrate
        guard let targetBitrate, targetBitrate > 0 else { return nil }
        return max(1.0, Double(targetBitrate) / 8.0 / Double(max(1, currentFrameRate)))
    }

    func receiverFrameBudgetIsHealthy(now: CFAbsoluteTime) -> Bool {
        guard lastReceiverFeedbackTime > 0, now - lastReceiverFeedbackTime <= 2.5 else { return true }
        if frameChainState != .normal { return false }
        if realtimePressureState == .recovery { return false }
        if receiverReassemblyBacklogFrames > 2 { return false }
        if receiverReassemblyBacklogBytes > 650_000 { return false }
        if receiverDecodeBacklogFrames > 2 { return false }
        if receiverPresentationBacklogFrames > 3 { return false }
        if receiverLostFrameCount > 0 || receiverDiscardedPacketCount > 0 { return false }
        let frameBudgetMs = 1_000.0 / Double(max(1, currentFrameRate))
        if let receiverAckLagMs,
           lastReceiverAckTime > 0,
           now - lastReceiverAckTime <= 1.0,
           receiverAckLagMs > frameBudgetMs * 2.0 {
            return false
        }
        return true
    }

    func receiverFrameBudgetCanLearnCapacity(now: CFAbsoluteTime) -> Bool {
        guard receiverFrameBudgetIsHealthy(now: now) else { return false }
        if startupTransportProtectionDeadline > now { return false }
        if receiverCapacityLearningQuarantineUntil > now { return false }
        return true
    }

    func receiverFrameBudgetCapacityLearningQuarantineReason(now: CFAbsoluteTime) -> String? {
        if startupTransportProtectionDeadline > now { return "startup" }
        if receiverCapacityLearningQuarantineUntil > now {
            return receiverCapacityLearningQuarantineReason ?? "receiver-quarantine"
        }
        if frameChainState != .normal { return "chain-repair" }
        if realtimePressureState == .recovery { return "host-recovery" }
        if receiverDecodeBacklogFrames > 2 { return "decode-backlog" }
        if receiverPresentationBacklogFrames > 3 { return "presentation-backlog" }
        if receiverLostFrameCount > 0 || receiverDiscardedPacketCount > 0 { return "receiver-loss" }
        if receiverReassemblyBacklogFrames > 2 || receiverReassemblyBacklogBytes > 650_000 { return "reassembly-backlog" }
        return nil
    }

    func updateReceiverCapacityLearningQuarantine(
        _ feedback: ReceiverMediaFeedbackMessage,
        now: CFAbsoluteTime
    ) {
        let decodeDepth = feedback.decodeQueueDepth ?? feedback.decodeBacklogFrames
        let presentationDepth = feedback.presentationQueueDepth ?? feedback.presentationBacklogFrames
        let reason: String? = if feedback.recoveryState != .idle {
            "recovery-\(feedback.recoveryState.rawValue)"
        } else if feedback.recoveryCause == .memoryBudget || decodeDepth > 2 {
            "decode-backlog"
        } else if presentationDepth > 3 || (feedback.presentationStallCount ?? 0) > 0 {
            "presentation-backlog"
        } else {
            nil
        }
        guard let reason else {
            if receiverCapacityLearningQuarantineUntil <= now {
                receiverCapacityLearningQuarantineReason = nil
            }
            return
        }
        receiverCapacityLearningQuarantineUntil = max(receiverCapacityLearningQuarantineUntil, now + 0.5)
        receiverCapacityLearningQuarantineReason = reason
    }

    private func senderFrameBudgetIsHealthy(now: CFAbsoluteTime) async -> Bool {
        guard let packetSender else { return true }
        let telemetry = await packetSender.telemetrySnapshot
        if telemetry.senderLocalDeadlineDrops > 0 { return false }
        if telemetry.nonKeyframeHoldDrops > 0 { return false }
        if telemetry.queuedBytes > queuePressureBytes { return false }
        let frameBudgetMs = 1_000.0 / Double(max(1, currentFrameRate))
        let hardPacerBudgetMs = frameBudgetMs * 3.0
        if telemetry.packetPacerFrameMaxSleepMs > Int(hardPacerBudgetMs.rounded(.up)) { return false }
        return true
    }

    func applyFrameTransportBudgetFeedback(
        _ completion: StreamPacketSender.FrameTransportCompletion,
        now: CFAbsoluteTime
    ) async {
        guard runtimeQualityAdjustmentEnabled, completion.didSend else { return }
        let decision = adaptivePFrameController.recordFrameTransportCompletion(
            frameNumber: UInt64(completion.frameNumber),
            wireBytes: completion.wireBytes,
            packetCount: completion.packetCount,
            isKeyframe: completion.isKeyframe,
            sendCompletionMs: completion.sendCompletionMs,
                timingSource: .localSendCompletion,
                receiverHealthy: receiverFrameBudgetIsHealthy(now: now),
                capacityLearningAllowed: false,
                capacityLearningQuarantineReason: "local-send-completion",
                currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            requestedTargetBitrateBps: requestedTargetBitrate,
            startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
            minimumBitrateFloorBps: realtimeMinimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: activeQuality,
            qualityFloor: qualityFloor,
            steadyQualityCeiling: steadyQualityCeiling,
            now: now
        )
        guard let decision else { return }
        await applyFrameBudgetDecision(decision, now: now)
    }

    func logAdaptivePFrameAdmissionIfNeeded(
        frameNumber: UInt32?,
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        evaluation: HostEncodedFrameAdmissionDecision,
        action: String,
        now: CFAbsoluteTime
    ) {
        guard now - encodedFrameQualityLastLogTime >= 0.5 else { return }
        encodedFrameQualityLastLogTime = now
        let activeWireBudget = evaluation.wireRatio > 0
            ? Double(wireBytes) / evaluation.wireRatio
            : (encodedFrameBudgetBytes() ?? 0)
        let activePacketBudget = evaluation.packetRatio > 0
            ? Double(packetCount) / evaluation.packetRatio
            : 0
        let baselineWireBytes = adaptivePFrameController.recentCleanPFrameBaselineWireBytes
        let baselinePackets = adaptivePFrameController.recentCleanPFrameBaselinePacketCount
        let allowedRatio = baselineWireBytes.map(HostAdaptivePFrameController.allowedPFrameSpikeRatio)
        let absoluteRatio = max(evaluation.byteRatio, max(evaluation.wireRatio, evaluation.packetRatio))
        let frameText = frameNumber.map(String.init) ?? "unreserved"
        let budgetKB = (activeWireBudget / 1024.0).formatted(.number.precision(.fractionLength(1)))
        let frameKB = (Double(byteCount) / 1024.0).formatted(.number.precision(.fractionLength(1)))
        let wireKB = (Double(wireBytes) / 1024.0).formatted(.number.precision(.fractionLength(1)))
        let ratioText = absoluteRatio.formatted(.number.precision(.fractionLength(2)))
        let baselineText = baselineWireBytes.map {
            (Double($0) / 1024.0).formatted(.number.precision(.fractionLength(1))) + "KB"
        } ?? "none"
        let baselinePacketText = baselinePackets.map(String.init) ?? "none"
        let allowedText = allowedRatio?.formatted(.number.precision(.fractionLength(2))) ?? "none"
        let packetBudgetText = activePacketBudget.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.metrics(
            "event=adaptive_p_frame_admission action=\(action) frame=\(frameText) " +
                "frameBytes=\(frameKB) wireBytes=\(wireKB) packets=\(packetCount) " +
                "activeWireBudget=\(budgetKB) activePacketBudget=\(packetBudgetText) " +
                "cleanBaseline=\(baselineText) cleanBaselinePackets=\(baselinePacketText) " +
                "allowedLogRatio=\(allowedText) absoluteRatio=\(ratioText)"
        )
    }

}
#endif
