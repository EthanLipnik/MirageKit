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

    /// Applies a conservative host-local change estimate before submitting the frame to VideoToolbox.
    /// Returns true when the current non-keyframe should be dropped before it can advance encoder references.
    func applyPreEncodeMotionBudgetIfNeeded(
        for frame: CapturedFrame,
        now: CFAbsoluteTime
    ) async -> Bool {
        guard runtimeQualityAdjustmentEnabled else { return false }
        guard encoderConfig.codec != .proRes4444 else { return false }
        guard let currentSample = HostFrameMotionSampler.sample(pixelBuffer: frame.pixelBuffer) else {
            previousFrameMotionSample = nil
            return false
        }
        defer { previousFrameMotionSample = currentSample }
        guard let estimate = HostFrameMotionSampler.estimate(
            previous: previousFrameMotionSample,
            current: currentSample
        ) else {
            return false
        }

        guard let decision = frameBudgetController.updateForFrameChange(
            estimate: estimate,
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
        ) else {
            return false
        }

        await applyFrameBudgetDecision(decision, now: now)
        logPreEncodeMotionBudgetIfNeeded(estimate: estimate, decision: decision, now: now)
        return shouldDropPreEncodeMotionFrame(estimate: estimate, decision: decision, now: now)
    }

    private func shouldDropPreEncodeMotionFrame(
        estimate: HostFrameChangeEstimate,
        decision: HostFrameBudgetDecision,
        now: CFAbsoluteTime
    ) -> Bool {
        guard decision.state == .severe else { return false }
        guard activeQuality <= qualityFloor + 0.01 else { return false }
        guard now - preEncodeMotionDropLastTime >= 0.20 else { return false }
        guard estimate.confidence >= 0.92 else { return false }
        return estimate.changedAreaRatio >= 0.72 || estimate.averageDelta >= 0.26
    }

    func shouldDropEncodedNonKeyframeForBudget(byteCount: Int) -> Bool {
        guard runtimeQualityAdjustmentEnabled, byteCount > 0 else { return false }
        guard let budgetBytes = encodedFrameBudgetBytes() else { return false }
        return Double(byteCount) > budgetBytes
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
            receiverHealthy: receiverFrameBudgetIsHealthy(now: now),
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

    func handleDroppedEncodedFrameForBudget(
        byteCount: Int,
        evaluation: HostEncodedFrameAdmissionDecision,
        encodedAt now: CFAbsoluteTime
    ) async {
        droppedFrameCount += 1
        qualityRaiseSuppressionUntil = max(
            qualityRaiseSuppressionUntil,
            now + qualityRaisePostSpikeCooldown
        )
        await scheduleCoalescedRecoveryKeyframe(
            reason: "Encoded-frame budget recovery",
            noteLoss: false,
            ignoreExistingInFlight: true
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
        qualityRaiseSuppressionUntil = max(
            qualityRaiseSuppressionUntil,
            now + qualityRaisePostSpikeCooldown
        )
        if let decision = evaluation.budgetDecision {
            await encoder?.prepareForKeyframe(quality: decision.keyframeQuality)
        }
        await scheduleCoalescedRecoveryKeyframe(
            reason: "Encoded keyframe budget recovery",
            noteLoss: false,
            ignoreExistingInFlight: true
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
        let target = Double(max(1, currentFrameRate))
        if receiverPresentationBacklogFrames > 1 { return false }
        let receiverFPS = [receiverDecodedFPS, receiverAcceptedFPS, receiverPresentedFPS]
            .filter { $0 > 0 }
            .min()
        guard let receiverFPS else { return true }
        return receiverFPS >= target * 0.85
    }

    private func logPreEncodeMotionBudgetIfNeeded(
        estimate: HostFrameChangeEstimate,
        decision: HostFrameBudgetDecision,
        now: CFAbsoluteTime
    ) {
        guard now - preEncodeMotionBudgetLastLogTime >= 0.5 else { return }
        preEncodeMotionBudgetLastLogTime = now
        let changedText = estimate.changedAreaRatio.formatted(.number.precision(.fractionLength(2)))
        let deltaText = estimate.averageDelta.formatted(.number.precision(.fractionLength(2)))
        let confidenceText = estimate.confidence.formatted(.number.precision(.fractionLength(2)))
        let bitrateText = "\((Double(decision.targetBitrateBps) / 1_000_000.0).formatted(.number.precision(.fractionLength(1))))Mbps"
        MirageLogger.metrics(
            "Pre-encode change estimate: stream=\(streamID) state=\(decision.state.rawValue) " +
                "target=\(bitrateText) changed=\(changedText) delta=\(deltaText) confidence=\(confidenceText)"
        )
    }

    func logPreEncodeMotionDropIfNeeded(now: CFAbsoluteTime) {
        guard now - preEncodeMotionDropLastLogTime >= 0.5 else { return }
        preEncodeMotionDropLastLogTime = now
        let qualityText = Double(activeQuality).formatted(.number.precision(.fractionLength(2)))
        let floorText = Double(qualityFloor).formatted(.number.precision(.fractionLength(2)))
        MirageLogger.metrics(
            "Dropped high-motion frame before encoder for stream \(streamID) " +
                "(quality=\(qualityText) floor=\(floorText))"
        )
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
