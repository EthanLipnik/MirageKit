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
    private static func formattedFPS(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func encoderCatchUpBacklogThresholdMs() -> Double {
        if mediaPathProfile.usesAwdlRadioPolicy {
            let frameBudgetMs = 1_000.0 / Double(max(1, currentFrameRate))
            return max(50.0, min(80.0, frameBudgetMs * 3.0))
        }

        let fixedCustomQuality = explicitEnteredTargetBitrate != nil &&
            !clientRequestedBitrateAdaptationCeiling
        if fixedCustomQuality {
            return 1_000
        }

        switch latencyMode {
        case .lowestLatency:
            return 0
        case .balanced:
            return 350
        case .smoothest:
            return 1_000
        }
    }

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
        encoderAverageEncodeMsSnapshot = encodeAvgMs
        encoderInFlightCountSnapshot = inFlightCount
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
            let encodeBacklogText = worstEncodeStartCaptureAgeMs.formatted(.number.precision(.fractionLength(1)))

            let callbackFailures = encoder?.consumeCallbackFailureCount() ?? 0

            MirageLogger.metrics(
                "Pipeline: ingress=\(ingressText)fps capture=\(captureText)fps drop=\(captureDroppedIntervalCount) " +
                    "bp=\(backpressureDropIntervalCount) encode=\(encodeText)fps attempt=\(attemptText)fps reject=\(encodeRejectedIntervalCount) " +
                    "skip(qFull=\(encodeSkipQueueFullIntervalCount) dim=\(encodeSkipDimensionIntervalCount) inactive=\(encodeSkipInactiveIntervalCount) " +
                    "session=\(encodeSkipNoSessionIntervalCount)) error=\(encodeErrorIntervalCount) cbFail=\(callbackFailures) " +
                    "synthetic=\(syntheticText)fps gap=\(captureGapText)ms inFlight=\(inFlightCount) buffer=\(pendingCount)/\(frameBufferDepth) " +
                    "queue=\(queueKB)KB encodeAvg=\(encodeAvgText)ms encodeBacklogMax=\(encodeBacklogText)ms"
            )
        }

        await updateInFlightLimitIfNeeded(
            averageEncodeMs: encodeAvgMs,
            pendingCount: pendingCount,
            at: now
        )
        await applyEncoderThroughputBudgetIfNeeded(
            averageEncodeMs: encodeAvgMs,
            encodeAttemptFPS: encodeAttemptFPS,
            encodedFPS: encodeFPS,
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
        worstEncodeStartCaptureAgeMs = 0
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

    func applyEncoderThroughputBudgetIfNeeded(
        averageEncodeMs: Double,
        encodeAttemptFPS: Double,
        encodedFPS: Double,
        at now: CFAbsoluteTime
    ) async {
        guard runtimeQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy,
              encoderConfig.codec != .proRes4444,
              averageEncodeMs > 0,
              currentFrameRate > 0,
              isRunning else {
            return
        }

        let cadenceTarget = MirageStreamCadenceTarget(
            sourceFPS: currentFrameRate,
            displayFPS: currentFrameRate,
            latencyMode: latencyMode
        )
        let frameBudgetMs = cadenceTarget.sourceFrameBudgetMs
        guard frameBudgetMs > 0 else { return }

        let pressureThreshold: Double
        let healthyThreshold: Double
        let minimumReductionRatio: Double
        switch latencyMode {
        case .lowestLatency:
            pressureThreshold = 1.08
            healthyThreshold = 0.82
            minimumReductionRatio = 0.68
        case .balanced:
            pressureThreshold = 1.25
            healthyThreshold = 0.84
            minimumReductionRatio = 0.74
        case .smoothest:
            pressureThreshold = 1.65
            healthyThreshold = 0.90
            minimumReductionRatio = 0.82
        }

        let currentBitrate = currentTargetBitrateBps ??
            encoderConfig.bitrate ??
            requestedTargetBitrate ??
            startupBitrate ??
            0
        let ceilingBitrate = bitrateAdaptationCeiling ??
            explicitEnteredTargetBitrate ??
            requestedTargetBitrate ??
            startupBitrate ??
            currentBitrate
        guard currentBitrate > 0, ceilingBitrate > 0 else { return }

        if averageEncodeMs >= frameBudgetMs * pressureThreshold {
            guard encoderCatchUpQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy else { return }
            let encoderBacklogMs = worstEncodeStartCaptureAgeMs
            let backlogThresholdMs = encoderCatchUpBacklogThresholdMs()
            guard backlogThresholdMs <= 0 || encoderBacklogMs >= backlogThresholdMs else { return }
            guard now - realtimeLastEncoderThroughputAdjustmentTime >= 0.45 else { return }
            if mediaPathProfile.usesAwdlRadioPolicy,
               (!runtimeQualityAdjustmentEnabled || !currentAwdlFrameBudgetReductionAllowed()) {
                realtimePressureState = .pressured
                realtimePressureReason = "awdl-encoder-throughput-gated"
                realtimeLastEncoderThroughputAdjustmentTime = now
                let appliedStructuralStep = await applyAwdlHostStructuralAdaptationIfNeeded(
                    reason: "encoder-throughput",
                    averageEncodeMs: averageEncodeMs,
                    frameBudgetMs: frameBudgetMs,
                    encodeAttemptFPS: encodeAttemptFPS,
                    encodedFPS: encodedFPS,
                    at: now
                )
                if !appliedStructuralStep {
                    MirageLogger.metrics(
                        "AWDL encoder throughput held quality for stream \(streamID): " +
                            "structural adaptation pending or exhausted " +
                            "fps=\(currentFrameRate) scale=\(streamScale) " +
                            "encodeAvg=\(averageEncodeMs.formatted(.number.precision(.fractionLength(1))))ms " +
                            "budget=\(frameBudgetMs.formatted(.number.precision(.fractionLength(1))))ms"
                    )
                }
                return
            }
            let budgetRatio = max(0.01, frameBudgetMs / averageEncodeMs)
            let reductionRatio = min(0.92, max(minimumReductionRatio, budgetRatio * 1.05))
            let minimumFloor = max(1, encoderThroughputMinimumBitrateFloorBps)
            let targetBitrate = max(
                minimumFloor,
                Int((Double(currentBitrate) * reductionRatio).rounded(.down))
            )
            guard targetBitrate < currentBitrate else { return }

            realtimePressureState = .pressured
            realtimePressureReason = "encoder-throughput"
            realtimeLastEncoderThroughputAdjustmentTime = now
            await applyRealtimeBudgetBitrate(
                targetBitrate,
                ceilingBitrateBps: ceilingBitrate,
                encoderRateHintBps: targetBitrate,
                senderPacingBitrateBps: targetBitrate,
                minimumBitrateFloorBps: minimumFloor,
                reason: "encoder-throughput"
            )
            let budgetText = frameBudgetMs.formatted(.number.precision(.fractionLength(1)))
            let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
            let backlogText = encoderBacklogMs.formatted(.number.precision(.fractionLength(1)))
            let thresholdText = backlogThresholdMs.formatted(.number.precision(.fractionLength(1)))
            MirageLogger.metrics(
                "Encoder throughput budget cut stream \(streamID): " +
                    "encodeAvg=\(avgText)ms budget=\(budgetText)ms backlog=\(backlogText)ms " +
                    "threshold=\(thresholdText)ms " +
                    "target=\(currentBitrate)->\(targetBitrate) attemptFPS=\(Self.formattedFPS(encodeAttemptFPS)) " +
                    "encodedFPS=\(Self.formattedFPS(encodedFPS))"
            )
            return
        }

        guard runtimeQualityAdjustmentEnabled else { return }
        guard currentBitrate < ceilingBitrate,
              averageEncodeMs <= frameBudgetMs * healthyThreshold,
              receiverFrameBudgetCanRaiseQuality(now: now),
              await senderFrameBudgetIsHealthy(now: now) else {
            return
        }
        guard now - realtimeLastEncoderThroughputAdjustmentTime >= 0.65 else { return }

        let policy = activeFrameFreshnessPolicy
        let sourceStill = sourceIsStill(now: now, policy: policy)
        let inputActive = inputIsActive(now: now, policy: policy)
        let raiseRatio = sourceStill && !inputActive ? 1.28 : 1.16
        let raiseStep = sourceStill && !inputActive ? 24_000_000 : 8_000_000
        let targetBitrate = min(
            ceilingBitrate,
            max(currentBitrate + raiseStep, Int((Double(currentBitrate) * raiseRatio).rounded(.up)))
        )
        guard targetBitrate > currentBitrate else { return }

        realtimePressureState = .observing
        realtimePressureReason = HostAdaptivePFrameController.Reason.healthy.rawValue
        realtimeLastEncoderThroughputAdjustmentTime = now
        await applyRealtimeBudgetBitrate(
            targetBitrate,
            ceilingBitrateBps: ceilingBitrate,
            encoderRateHintBps: targetBitrate,
            senderPacingBitrateBps: targetBitrate,
            reason: HostAdaptivePFrameController.Reason.healthy.rawValue
        )
        let budgetText = frameBudgetMs.formatted(.number.precision(.fractionLength(1)))
        let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.metrics(
            "Encoder throughput budget raised stream \(streamID): " +
                "encodeAvg=\(avgText)ms budget=\(budgetText)ms " +
                "target=\(currentBitrate)->\(targetBitrate) attemptFPS=\(Self.formattedFPS(encodeAttemptFPS)) " +
                "encodedFPS=\(Self.formattedFPS(encodedFPS))"
        )
    }

    @discardableResult
    func applyAwdlHostStructuralAdaptationIfNeeded(
        reason: String,
        averageEncodeMs: Double? = nil,
        frameBudgetMs: Double? = nil,
        encodeAttemptFPS: Double? = nil,
        encodedFPS: Double? = nil,
        at now: CFAbsoluteTime
    ) async -> Bool {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return false }
        let targetFPS: Int
        if currentFrameRate > 45 {
            targetFPS = 45
        } else if currentFrameRate > 30 {
            targetFPS = 30
        } else {
            return await applyAwdlHostStructuralScaleStepIfNeeded(
                reason: reason,
                averageEncodeMs: averageEncodeMs,
                frameBudgetMs: frameBudgetMs,
                encodeAttemptFPS: encodeAttemptFPS,
                encodedFPS: encodedFPS,
                at: now
            )
        }
        guard lastAwdlInteractiveFrameRateAdjustmentTime == 0 ||
            now - lastAwdlInteractiveFrameRateAdjustmentTime >= 1.0 else {
            pendingAwdlInteractiveFrameRate = targetFPS
            pendingAwdlInteractiveFrameRateReason = reason
            return false
        }
        let applied = await applyAwdlInteractiveFrameRate(targetFPS, now: now, reason: reason)
        MirageLogger.metrics(
            "AWDL host structural cadence step for stream \(streamID): " +
                "targetFPS=\(targetFPS) reason=\(reason) applied=\(applied) " +
                awdlHostStructuralPressureMetrics(
                    averageEncodeMs: averageEncodeMs,
                    frameBudgetMs: frameBudgetMs,
                    encodeAttemptFPS: encodeAttemptFPS,
                    encodedFPS: encodedFPS
                )
        )
        return applied
    }

    private func applyAwdlHostStructuralScaleStepIfNeeded(
        reason: String,
        averageEncodeMs: Double?,
        frameBudgetMs: Double?,
        encodeAttemptFPS: Double?,
        encodedFPS: Double?,
        at now: CFAbsoluteTime
    ) async -> Bool {
        let baseScale = awdlInteractiveBaseStreamScale ?? requestedStreamScale
        let currentMultiplier = baseScale > 0 ? Double(streamScale / baseScale) : 1.0
        let targetMultiplier: Double
        if currentMultiplier > 0.876 {
            targetMultiplier = 0.875
        } else if currentMultiplier > 0.751 {
            targetMultiplier = 0.75
        } else {
            if currentFrameRate <= 30 {
                grantAwdlHostStructuralQualityReduction(now: now, reason: reason)
            } else {
                clearAwdlHostStructuralQualityReduction()
            }
            return false
        }

        let applied = await applyAwdlInteractiveScale(
            targetMultiplier,
            now: now,
            reason: reason
        )
        if applied {
            let effectiveMultiplier = baseScale > 0 ? Double(streamScale / baseScale) : targetMultiplier
            if currentFrameRate <= 30 && effectiveMultiplier <= 0.751 {
                grantAwdlHostStructuralQualityReduction(now: now, reason: reason)
            } else {
                clearAwdlHostStructuralQualityReduction()
            }
        }
        MirageLogger.metrics(
            "AWDL host structural scale step for stream \(streamID): " +
                "targetMultiplier=\(targetMultiplier.formatted(.number.precision(.fractionLength(3)))) " +
                "currentMultiplier=\(currentMultiplier.formatted(.number.precision(.fractionLength(3)))) " +
                "reason=\(reason) applied=\(applied) " +
                awdlHostStructuralPressureMetrics(
                    averageEncodeMs: averageEncodeMs,
                    frameBudgetMs: frameBudgetMs,
                    encodeAttemptFPS: encodeAttemptFPS,
                    encodedFPS: encodedFPS
                )
        )
        return applied
    }

    private func awdlHostStructuralPressureMetrics(
        averageEncodeMs: Double?,
        frameBudgetMs: Double?,
        encodeAttemptFPS: Double?,
        encodedFPS: Double?
    ) -> String {
        var components: [String] = []
        if let averageEncodeMs {
            components.append("encodeAvg=\(averageEncodeMs.formatted(.number.precision(.fractionLength(1))))ms")
        }
        if let frameBudgetMs {
            components.append("budget=\(frameBudgetMs.formatted(.number.precision(.fractionLength(1))))ms")
        }
        if let encodeAttemptFPS {
            components.append("attemptFPS=\(Self.formattedFPS(encodeAttemptFPS))")
        }
        if let encodedFPS {
            components.append("encodedFPS=\(Self.formattedFPS(encodedFPS))")
        }
        return components.joined(separator: " ")
    }

    func evaluateEncodedFrameBudget(
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        isKeyframe: Bool,
        encodedAt now: CFAbsoluteTime
    ) async -> HostEncodedFrameAdmissionDecision {
        guard runtimeQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy,
              byteCount > 0 else {
            return HostEncodedFrameAdmissionDecision(
                admission: .send,
                budgetDecision: nil,
                sendDeadline: now + 1.0 / Double(max(1, currentFrameRate)),
                byteRatio: 0,
                wireRatio: 0,
                packetRatio: 0
            )
        }
        let freshnessPolicy = activeFrameFreshnessPolicy
        let inputActive = inputIsActive(now: now, policy: freshnessPolicy)
        let sourceStill = sourceIsStill(now: now, policy: freshnessPolicy)
        let decision = adaptivePFrameController.evaluateEncodedFrame(
            byteCount: byteCount,
            wireBytes: wireBytes,
            packetCount: packetCount,
            isKeyframe: isKeyframe,
            receiverHealthy: receiverFrameBudgetCanRaiseQuality(now: now),
            senderHealthy: await senderFrameBudgetIsHealthy(now: now),
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
            awdlQualityReductionAllowed: currentAwdlQualityReductionAllowed(),
            now: now
        )
        if !isKeyframe,
           awdlEncodedPFrameNeedsStructuralAdaptation(decision) {
            await applyAwdlHostStructuralAdaptationIfNeeded(
                reason: "encoded-frame-oversize",
                at: now
            )
        }
        if !isKeyframe, let budgetDecision = decision.budgetDecision {
            await applyFrameBudgetDecision(budgetDecision, now: now)
        }
        return decision
    }

    func handleDroppedPFrameForTransportBudget(
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        evaluation: HostEncodedFrameAdmissionDecision,
        encodedAt now: CFAbsoluteTime
    ) async {
        droppedFrameCount += 1
        await applyAwdlHostStructuralAdaptationIfNeeded(
            reason: "encoded-frame-catastrophic-oversize",
            at: now
        )
        startFrameChainRepair(
            reason: "transport-p-frame-catastrophic-oversize",
            now: now
        )
        await noteEmergencyKeyframePrepared(using: evaluation.budgetDecision)
        await scheduleEmergencyChainRepairKeyframe(
            reason: "Transport P-frame catastrophic oversize",
            bypassesRecoveryCooldown: true,
            now: now
        )
        logAdaptivePFrameAdmissionIfNeeded(
            frameNumber: nil,
            byteCount: byteCount,
            wireBytes: wireBytes,
            packetCount: packetCount,
            evaluation: evaluation,
            action: "drop-catastrophic-chain-repair",
            now: now
        )
    }

    private func awdlEncodedPFrameNeedsStructuralAdaptation(
        _ decision: HostEncodedFrameAdmissionDecision
    ) -> Bool {
        guard mediaPathProfile.usesAwdlRadioPolicy,
              !currentAwdlFrameBudgetReductionAllowed() else {
            return false
        }
        let oversizeRatio = max(decision.byteRatio, max(decision.wireRatio, decision.packetRatio))
        return oversizeRatio >= 1.20
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

    var activeFrameFreshnessPolicy: HostFrameFreshnessPolicy {
        HostFrameFreshnessPolicy.policy(
            for: latencyMode,
            frameRate: currentFrameRate,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs
        )
    }

    private func receiverAckLagBudgetMs(
        frameBudgetMs: Double,
        standardFrameCount: Double,
        awdlExtraFrameCount: Double
    ) -> Double {
        let standardBudgetMs = frameBudgetMs * standardFrameCount
        guard mediaPathProfile.usesAwdlRadioPolicy else { return standardBudgetMs }
        let playoutBudgetMs = min(
            MirageAwdlMediaController.maximumPlayoutDelayMs,
            max(
                MirageAwdlMediaController.minimumPlayoutDelayMs,
                receiverPlayoutDelayTargetMs ?? MirageAwdlMediaController.basePlayoutDelayMs
            )
        )
        return max(standardBudgetMs, playoutBudgetMs + frameBudgetMs * awdlExtraFrameCount)
    }

    func inputIsActive(
        now: CFAbsoluteTime,
        policy: HostFrameFreshnessPolicy? = nil
    ) -> Bool {
        let activePolicy = policy ?? activeFrameFreshnessPolicy
        return activePolicy.inputIsActive(lastInputTime: lastClientInputTime, now: now)
    }

    func sourceIsStill(
        now: CFAbsoluteTime,
        policy: HostFrameFreshnessPolicy? = nil
    ) -> Bool {
        let activePolicy = policy ?? activeFrameFreshnessPolicy
        return activePolicy.sourceIsStill(
            lastNonIdleCaptureTime: lastNonIdleCapturedFrameTime,
            latestFrameIsIdle: lastCapturedFrame?.info.isIdleFrame == true,
            now: now
        )
    }

    func updateIdleQualityProbeAdmissionHint(now: CFAbsoluteTime) {
        shouldAdmitIdleQualityProbeFrame = pendingKeyframeReason != nil ||
            shouldConsiderStillQualityProbe(now: now)
    }

    func shouldEncodeStillQualityProbeFrame(now: CFAbsoluteTime) -> Bool {
        shouldConsiderStillQualityProbe(now: now)
    }

    @discardableResult
    func scheduleStillQualityProbeIfNeeded(
        now: CFAbsoluteTime,
        reason: String
    ) -> Bool {
        guard shouldConsiderStillQualityProbe(now: now) else { return false }
        shouldAdmitIdleQualityProbeFrame = true
        let shouldScheduleDrain = enqueueSyntheticFrameFromLastCaptureIfNeeded(now: now, reason: reason)
        guard shouldScheduleDrain else {
            return false
        }
        lastStillQualityProbeEncodeTime = now
        scheduleProcessingAfterFrameInboxEnqueue(shouldScheduleDrain)
        MirageLogger.metrics(
            "Still quality probe scheduled for stream \(streamID): reason=\(reason)"
        )
        return true
    }

    private func shouldConsiderStillQualityProbe(now: CFAbsoluteTime) -> Bool {
        let policy = activeFrameFreshnessPolicy
        let inputActive = inputIsActive(now: now, policy: policy)
        let sourceStill = sourceIsStill(now: now, policy: policy)
        guard runtimeQualityAdjustmentEnabled, !inputActive else { return false }
        guard activeQuality + 0.005 < configuredQualityCeiling else { return false }
        guard now - lastStillQualityProbeEncodeTime >= policy.stillQualityProbeInterval else { return false }
        guard (packetSender?.queuedByteCount ?? 0) <= queuePressureBytes else { return false }
        guard !mediaPathProfile.usesAwdlRadioPolicy || receiverFeedbackIsFresh(now: now) else {
            return false
        }
        return sourceStill || receiverFrameBudgetCanRaiseQuality(now: now)
    }

    func receiverFrameBudgetIsHealthy(now: CFAbsoluteTime) -> Bool {
        guard receiverFeedbackIsFresh(now: now) else {
            return !mediaPathProfile.usesAwdlRadioPolicy
        }
        if frameChainState != .normal { return false }
        if realtimePressureState == .recovery { return false }
        if receiverReassemblyBacklogFrames > 2 { return false }
        if receiverReassemblyBacklogBytes > 650_000 { return false }
        if receiverDecodeBacklogFrames > 2 { return false }
        if receiverPresentationBacklogFrames > 3 { return false }
        if receiverLostFrameCount > 0 || receiverDiscardedPacketCount > 0 { return false }
        let frameBudgetMs = 1_000.0 / Double(max(1, currentFrameRate))
        let ackLagBudgetMs = receiverAckLagBudgetMs(
            frameBudgetMs: frameBudgetMs,
            standardFrameCount: 2.0,
            awdlExtraFrameCount: 1.0
        )
        if let receiverAckLagMs,
           lastReceiverAckTime > 0,
           now - lastReceiverAckTime <= 1.0,
           receiverAckLagMs > ackLagBudgetMs {
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

    func receiverFrameBudgetCanRaiseQuality(now: CFAbsoluteTime) -> Bool {
        guard receiverFeedbackIsFresh(now: now) else {
            return !mediaPathProfile.usesAwdlRadioPolicy
        }
        if frameChainState != .normal { return false }
        if realtimePressureState == .recovery { return false }
        if receiverLostFrameCount > 0 || receiverDiscardedPacketCount > 0 { return false }
        let policy = activeFrameFreshnessPolicy
        let inputActive = inputIsActive(now: now, policy: policy)
        let sourceStill = sourceIsStill(now: now, policy: policy)
        let allowedReassemblyBacklogFrames = sourceStill && !inputActive
            ? min(2, policy.stillMaxUnstartedPFrames)
            : 0
        let allowedReassemblyBacklogBytes = sourceStill && !inputActive ? 256 * 1024 : 0
        if receiverReassemblyBacklogFrames > allowedReassemblyBacklogFrames { return false }
        if receiverReassemblyBacklogBytes > allowedReassemblyBacklogBytes { return false }
        let allowedDecodeBacklog = sourceStill && !inputActive ? 1 : 0
        if receiverDecodeBacklogFrames > allowedDecodeBacklog { return false }
        if !policy.allowsPresentationFreshness(
            depth: receiverPresentationBacklogFrames,
            latestPresentedFrameAgeMs: receiverLatestPresentedFrameAgeMs,
            inputActive: inputActive,
            sourceStill: sourceStill
        ) {
            return false
        }
        let frameBudgetMs = 1_000.0 / Double(max(1, currentFrameRate))
        let ackLagBudgetMs = receiverAckLagBudgetMs(
            frameBudgetMs: frameBudgetMs,
            standardFrameCount: 3.0,
            awdlExtraFrameCount: 2.0
        )
        if let receiverAckLagMs,
           lastReceiverAckTime > 0,
           now - lastReceiverAckTime <= 1.0,
           receiverAckLagMs > ackLagBudgetMs {
            return false
        }
        return true
    }

    func receiverFrameBudgetCapacityLearningQuarantineReason(now: CFAbsoluteTime) -> String? {
        if mediaPathProfile.usesAwdlRadioPolicy, !receiverFeedbackIsFresh(now: now) {
            return "receiver-feedback-stale"
        }
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
        let frameBudgetMs = 1_000.0 / Double(max(1, currentFrameRate))
        let ackLagBudgetMs = receiverAckLagBudgetMs(
            frameBudgetMs: frameBudgetMs,
            standardFrameCount: 2.0,
            awdlExtraFrameCount: 1.0
        )
        if let receiverAckLagMs,
           lastReceiverAckTime > 0,
           now - lastReceiverAckTime <= 1.0,
           receiverAckLagMs > ackLagBudgetMs {
            return "receiver-ack-lag"
        }
        return nil
    }

    private func receiverFeedbackIsFresh(
        now: CFAbsoluteTime,
        maxAge: CFAbsoluteTime = 2.5
    ) -> Bool {
        lastReceiverFeedbackTime > 0 && now - lastReceiverFeedbackTime <= maxAge
    }

    func updateReceiverCapacityLearningQuarantine(
        _ feedback: ReceiverMediaFeedbackMessage,
        now: CFAbsoluteTime
    ) {
        let decodeDepth = feedback.decodeQueueDepth ?? feedback.decodeBacklogFrames
        let presentationDepth = resolvedReceiverPresentationBacklogFrames(feedback)
        let reason: String? = if feedback.recoveryState != .idle {
            "recovery-\(feedback.recoveryState.rawValue)"
        } else if feedback.recoveryCause == .memoryBudget || decodeDepth > 2 {
            "decode-backlog"
        } else if presentationDepth > 3 {
            "presentation-backlog"
        } else if (feedback.presentationStallCount ?? 0) > 0 {
            "presentation-underflow"
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
        guard runtimeQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy,
              completion.didSend else { return }
        let decision = adaptivePFrameController.recordFrameTransportCompletion(
            frameNumber: UInt64(completion.frameNumber),
            wireBytes: completion.wireBytes,
            packetCount: completion.packetCount,
            isKeyframe: completion.isKeyframe,
            sendCompletionMs: completion.sendCompletionMs,
            timingSource: .localSendCompletion,
            receiverHealthy: receiverFrameBudgetIsHealthy(now: now),
            capacityLearningAllowed: false,
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
            awdlQualityReductionAllowed: currentAwdlQualityReductionAllowed(),
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
