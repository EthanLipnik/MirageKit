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
        let hasFreshReceiverFeedback = lastReceiverFeedbackTime > 0 && now - lastReceiverFeedbackTime <= 2.5
        let receiverHealthy = !smoothnessFirstMode || !hasFreshReceiverFeedback || (
            receiverPresentationBacklogFrames <= (currentFrameRate >= 90 ? 2 : 1) &&
                receiverAcceptedFPS >= Double(currentFrameRate) * 0.85 &&
                receiverPresentedFPS >= Double(currentFrameRate) * 0.85
        )
        let receiverUnderRun = smoothnessFirstMode &&
            hasFreshReceiverFeedback &&
            receiverPresentedFPS > 0 &&
            receiverPresentedFPS < Double(currentFrameRate) * 0.75
        if averageEncodeMs > frameBudgetMs * increaseThreshold || pendingCount > 0 || receiverUnderRun {
            desired = min(maxInFlightFrames + 1, maxInFlightFramesCap)
        } else if averageEncodeMs < frameBudgetMs * decreaseThreshold, pendingCount == 0, receiverHealthy {
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
        let decision = frameBudgetController.evaluateEncodedFrame(
            byteCount: byteCount,
            wireBytes: wireBytes,
            packetCount: packetCount,
            isKeyframe: isKeyframe,
            isRecoveryKeyframe: isKeyframe && keyframeUsesEmergencyBudget,
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
        if let budgetDecision = decision.budgetDecision {
            await applyFrameBudgetDecision(budgetDecision, now: now)
        }
        return decision
    }

    private var keyframeUsesEmergencyBudget: Bool {
        pendingEmergencyKeyframeQuality != nil || frameChainState != .normal
    }

    func handleDroppedEncodedFrameForBudget(
        byteCount: Int,
        evaluation: HostEncodedFrameAdmissionDecision,
        encodedAt now: CFAbsoluteTime
    ) async {
        droppedFrameCount += 1
        startFrameChainRepair(
            reason: "encoded-frame-over-budget",
            now: now
        )
        qualityRaiseSuppressionUntil = max(
            qualityRaiseSuppressionUntil,
            now + qualityRaisePostSpikeCooldown
        )
        await noteEmergencyKeyframePrepared(using: evaluation.budgetDecision)
        await scheduleEmergencyChainRepairKeyframe(
            reason: "Encoded-frame budget recovery",
            bypassesRecoveryCooldown: recoveryCauseBypassesAdaptiveKeyframeCooldown(latestReceiverRecoveryCause),
            now: now
        )
        let budgetBytes = encodedFrameBudgetBytes() ?? 0
        let ratio = max(evaluation.byteRatio, max(evaluation.wireRatio, evaluation.packetRatio))
        logDroppedEncodedFrameForBudgetIfNeeded(
            byteCount: byteCount,
            budgetBytes: budgetBytes,
            ratio: ratio,
            now: now
        )
    }

    func handleDroppedKeyframeForBudget(
        byteCount: Int,
        evaluation: HostEncodedFrameAdmissionDecision,
        encodedAt now: CFAbsoluteTime
    ) async {
        droppedFrameCount += 1
        startFrameChainRepair(
            reason: "encoded-keyframe-over-budget",
            now: now
        )
        qualityRaiseSuppressionUntil = max(
            qualityRaiseSuppressionUntil,
            now + qualityRaisePostSpikeCooldown
        )
        if keyframeUsesEmergencyBudget {
            await advanceEmergencyRecoveryScaleIfPossible(
                reason: "encoded-keyframe-over-budget",
                now: now
            )
        }
        await lowerEmergencyKeyframeQuality(using: evaluation.budgetDecision)
        await scheduleEmergencyChainRepairKeyframe(
            reason: "Encoded keyframe budget recovery",
            bypassesRecoveryCooldown: recoveryCauseBypassesAdaptiveKeyframeCooldown(latestReceiverRecoveryCause),
            now: now
        )
        let budgetBytes = encodedFrameBudgetBytes() ?? 0
        let ratio = max(evaluation.byteRatio, max(evaluation.wireRatio, evaluation.packetRatio))
        logDroppedEncodedFrameForBudgetIfNeeded(
            byteCount: byteCount,
            budgetBytes: budgetBytes,
            ratio: ratio,
            now: now
        )
    }

    /// Applies runtime encoder quality changes using queue pressure and encode timing.
    func adjustQualityForQueue(queueBytes: Int) async {
        guard let encoder else { return }
        guard runtimeQualityAdjustmentEnabled else { return }
        qualityCeiling = resolvedQualityCeiling
        if activeQuality > qualityCeiling {
            activeQuality = qualityCeiling
            await encoder.updateQuality(activeQuality)
        }
        let now = CFAbsoluteTimeGetCurrent()
        if lastQualityAdjustmentTime > 0, now - lastQualityAdjustmentTime < qualityAdjustmentCooldown { return }

        let transportOverBudget = queueBytes > queuePressureBytes
        let allowsRaise = false
        let allowTransportQualityRelief = true
        let baseDropThreshold = qualityDropThreshold
        let baseDropStep = qualityDropStep

        let decision = MirageRuntimeQualityAdjustmentPolicy.decide(
            state: MirageRuntimeQualityAdjustmentState(
                activeQuality: activeQuality,
                qualityOverBudgetCount: qualityOverBudgetCount,
                qualityUnderBudgetCount: qualityUnderBudgetCount
            ),
            qualityFloor: qualityFloor,
            qualityCeiling: qualityCeiling,
            transportOverBudget: transportOverBudget,
            encodedFrameUnderBudget: false,
            allowsRaise: allowsRaise,
            allowTransportQualityRelief: allowTransportQualityRelief,
            qualityDropThreshold: baseDropThreshold,
            qualityRaiseThreshold: qualityRaiseThreshold,
            qualityDropStep: baseDropStep,
            qualityRaiseStep: qualityRaiseStep
        )

        let previousQuality = activeQuality
        activeQuality = decision.state.activeQuality
        qualityOverBudgetCount = decision.state.qualityOverBudgetCount
        qualityUnderBudgetCount = decision.state.qualityUnderBudgetCount

        switch decision.action {
        case .hold:
            return

        case let .drop(reason):
            guard activeQuality < previousQuality else { return }
            qualityRaiseSuppressionUntil = max(qualityRaiseSuppressionUntil, now + qualityRaisePostSpikeCooldown)
            await encoder.updateQuality(activeQuality)
            lastQualityAdjustmentTime = now
            let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
            MirageLogger.metrics(
                "Quality down to \(qualityText) (queue \(queueBytes / 1024)KB, reason=\(reason))"
            )

        case .raise:
            guard activeQuality > previousQuality else { return }
            await encoder.updateQuality(activeQuality)
            lastQualityAdjustmentTime = now
            let qualityText = activeQuality.formatted(.number.precision(.fractionLength(2)))
            MirageLogger.metrics(
                "Quality up to \(qualityText) (queue \(queueBytes / 1024)KB)"
            )
        }
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

    private func receiverFrameBudgetIsHealthy(now: CFAbsoluteTime) -> Bool {
        guard lastReceiverFeedbackTime > 0, now - lastReceiverFeedbackTime <= 2.5 else { return true }
        if frameChainState != .normal { return false }
        if realtimePressureState == .recovery { return false }
        if receiverPresentationBacklogFrames > 1 { return false }
        if receiverReassemblyBacklogFrames > 2 { return false }
        if receiverReassemblyBacklogBytes > 650_000 { return false }
        if receiverDecodeBacklogFrames > 1 { return false }
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

    private func senderFrameBudgetIsHealthy(now: CFAbsoluteTime) async -> Bool {
        guard let packetSender else { return true }
        let telemetry = await packetSender.telemetrySnapshot
        if telemetry.senderLocalDeadlineDrops > 0 { return false }
        if telemetry.nonKeyframeHoldDrops > 0 { return false }
        if telemetry.queuedBytes > queuePressureBytes { return false }
        let frameBudgetMs = 1_000.0 / Double(max(1, currentFrameRate))
        let hardTransportBudgetMs = frameBudgetMs * 2.0
        if telemetry.nonKeyframeSendStartDelayMaxMs > hardTransportBudgetMs { return false }
        if telemetry.nonKeyframeSendCompletionMaxMs > hardTransportBudgetMs { return false }
        if telemetry.packetPacerFrameMaxSleepMs > Int(hardTransportBudgetMs.rounded(.up)) { return false }
        return true
    }

    private func logDroppedEncodedFrameForBudgetIfNeeded(
        byteCount: Int,
        budgetBytes: Double,
        ratio: Double,
        now: CFAbsoluteTime
    ) {
        guard now - encodedFrameQualityLastLogTime >= 0.5 else { return }
        encodedFrameQualityLastLogTime = now
        let budgetKB = (budgetBytes / 1024.0).formatted(.number.precision(.fractionLength(1)))
        let frameKB = (Double(byteCount) / 1024.0).formatted(.number.precision(.fractionLength(1)))
        let ratioText = ratio.formatted(.number.precision(.fractionLength(2)))
        MirageLogger.metrics(
            "Dropped encoded frame over budget before send " +
                "(frame=\(frameKB)KB budget=\(budgetKB)KB ratio=\(ratioText))"
        )
    }

}
#endif
