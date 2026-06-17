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

    private static let encoderThroughputBaselineSmoothing = 0.20
    private static let encoderThroughputSpikePressureRatio = 1.35
    private static let encoderThroughputCleanBacklogMinimumMs = 80.0
    private static let encoderThroughputCleanBacklogSampleRatio = 1.50
    private static let highRefreshQualityBudgetFrameRate = 60
    private static let highRefreshQualityBudgetThresholdFrameRate = 100
    private static let mostlyStillDirtyPercentage: Float = 1.0
    private static let lowMotionRampDirtyPercentage: Float = 6.0
    private static let lowMotionRampRequiredCleanFrames = 3
    private static let realtimePressureDecaySeconds: CFAbsoluteTime = 2.5

    private enum EncodedFrameMotionClass {
        case still
        case mostlyStill
        case lowMotion
        case highMotion

        var deliveryMode: HostFrameDeliveryMode {
            switch self {
            case .still,
                 .mostlyStill,
                 .lowMotion:
                .lowMotionRamp
            case .highMotion:
                .realtime
            }
        }
    }

    /// Advertised in stream metrics so clients know this host's realtime governor
    /// owns automatic bitrate and they should not run their own probe loop.
    static let realtimeControlRevision = 1

    /// Pressure states are set by discrete cut decisions; without raises (an idle
    /// screen starves them) the last state would otherwise latch forever, holding
    /// remote adaptation loops in their post-instability state. Decay back to
    /// observing once no detector has fired for a quiet window and the sender
    /// queue is drained.
    func decayRealtimePressureStateIfStale(now: CFAbsoluteTime) {
        guard realtimePressureState != .observing else { return }
        guard now - adaptivePFrameController.latestDecisionTime >= Self.realtimePressureDecaySeconds,
              now - realtimeLastEncoderThroughputAdjustmentTime >= Self.realtimePressureDecaySeconds,
              receiverFrameBudgetLossHoldUntil <= now,
              senderFrameBudgetDropHoldUntil <= now,
              (packetSender?.queuedByteCount ?? 0) <= queuePressureBytes / 2 else {
            return
        }
        realtimePressureState = .observing
        realtimePressureReason = HostAdaptivePFrameController.Reason.healthy.rawValue
        MirageLogger.stream(
            "Realtime pressure decayed to observing for stream \(streamID) after quiet window"
        )
    }

    func runtimeQualityBudgetFrameRate() -> Int {
        guard currentFrameRate >= Self.highRefreshQualityBudgetThresholdFrameRate,
              !mediaPathProfile.usesAwdlRadioPolicy else {
            return max(1, currentFrameRate)
        }
        return Self.highRefreshQualityBudgetFrameRate
    }

    func runtimeQualityFrameBudgetMs() -> Double {
        1_000.0 / Double(runtimeQualityBudgetFrameRate())
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
            let frameBudgetMs = 1_000.0 / Double(max(1, currentFrameRate))
            return max(50.0, min(90.0, frameBudgetMs * 3.0))
        case .balanced:
            return 350
        case .smoothest:
            return 1_000
        }
    }

    private func encoderThroughputBaselineKey() -> String {
        let width = Int(max(1, currentEncodedSize.width).rounded())
        let height = Int(max(1, currentEncodedSize.height).rounded())
        let scale = Double(streamScale)
        return "\(width)x\(height)|\(encoderConfig.codec.rawValue)|\(String(format: "%.3f", scale))"
    }

    @discardableResult
    private func refreshEncoderThroughputBaselineIfClean(
        averageEncodeMs: Double,
        encodeAttemptFPS: Double,
        encodedFPS: Double
    ) -> Double? {
        let key = encoderThroughputBaselineKey()
        if encoderThroughputHealthyBaselineKey != key {
            encoderThroughputHealthyBaselineKey = key
            encoderThroughputHealthyBaselineMs = nil
        }

        guard averageEncodeMs.isFinite,
              averageEncodeMs > 0,
              encodeAttemptFPS > 0,
              encodedFPS > 0 else {
            return encoderThroughputHealthyBaselineMs
        }

        let cleanBacklogLimit = max(
            Self.encoderThroughputCleanBacklogMinimumMs,
            averageEncodeMs * Self.encoderThroughputCleanBacklogSampleRatio
        )
        guard worstEncodeStartCaptureAgeMs <= cleanBacklogLimit,
              frameInbox.pendingCount <= 1 else {
            return encoderThroughputHealthyBaselineMs
        }

        if let baseline = encoderThroughputHealthyBaselineMs {
            let alpha = Self.encoderThroughputBaselineSmoothing
            encoderThroughputHealthyBaselineMs = baseline + (averageEncodeMs - baseline) * alpha
        } else {
            encoderThroughputHealthyBaselineMs = averageEncodeMs
        }
        return encoderThroughputHealthyBaselineMs
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
                    "bp=\(backpressureDropIntervalCount) transportSkip=\(transportAdmissionSkippedIntervalCount) " +
                    "encode=\(encodeText)fps attempt=\(attemptText)fps reject=\(encodeRejectedIntervalCount) " +
                    "skip(qFull=\(encodeSkipQueueFullIntervalCount) dim=\(encodeSkipDimensionIntervalCount) inactive=\(encodeSkipInactiveIntervalCount) " +
                    "session=\(encodeSkipNoSessionIntervalCount) pixelFormat=\(encodeSkipPixelFormatMismatchIntervalCount)) error=\(encodeErrorIntervalCount) cbFail=\(callbackFailures) " +
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
            captureFPS: captureFPS,
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
        transportAdmissionSkippedIntervalCount = 0
        encodeSkipQueueFullIntervalCount = 0
        encodeSkipDimensionIntervalCount = 0
        encodeSkipInactiveIntervalCount = 0
        encodeSkipNoSessionIntervalCount = 0
        encodeSkipPixelFormatMismatchIntervalCount = 0
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
        captureFPS: Double,
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

        let frameBudgetMs = runtimeQualityFrameBudgetMs()
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

        let encoderBacklogMs = worstEncodeStartCaptureAgeMs
        let pendingCount = frameInbox.pendingCount
        let encoderBaselineMs = refreshEncoderThroughputBaselineIfClean(
            averageEncodeMs: averageEncodeMs,
            encodeAttemptFPS: encodeAttemptFPS,
            encodedFPS: encodedFPS
        )
        let cadencePressureThresholdMs = frameBudgetMs * pressureThreshold
        let encodePressureThresholdMs = if mediaPathProfile.usesAwdlRadioPolicy {
            cadencePressureThresholdMs
        } else {
            encoderBaselineMs.map {
                max(cadencePressureThresholdMs, $0 * Self.encoderThroughputSpikePressureRatio)
            } ?? cadencePressureThresholdMs
        }

        let captureCadenceActive = captureFPS >= max(12.0, Double(currentFrameRate) * 0.45)
        let encodeCadenceFPS = min(
            encodeAttemptFPS > 0 ? encodeAttemptFPS : encodedFPS,
            encodedFPS > 0 ? encodedFPS : encodeAttemptFPS
        )
        let cadenceRatio = captureFPS > 0 ? encodeCadenceFPS / max(1.0, captureFPS) : 1.0
        let cadenceBacklogConfirmsPressure =
            encoderBacklogMs >= max(frameBudgetMs * 1.5, frameBudgetMs + 10.0) ||
            pendingCount > 1 ||
            averageEncodeMs >= frameBudgetMs * 0.95
        let hostCadenceBehind =
            mediaPathProfile.usesLocalBulkTransportPolicy &&
            captureCadenceActive &&
            encodeCadenceFPS > 0 &&
            encodeCadenceFPS < captureFPS * 0.86 &&
            cadenceBacklogConfirmsPressure

        if averageEncodeMs >= encodePressureThresholdMs || hostCadenceBehind {
            guard encoderCatchUpQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy else { return }
            let backlogThresholdMs = encoderCatchUpBacklogThresholdMs()
            guard hostCadenceBehind || backlogThresholdMs <= 0 || encoderBacklogMs >= backlogThresholdMs else { return }
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
            let budgetRatio = max(0.01, frameBudgetMs / max(1.0, averageEncodeMs))
            let cadenceScale = hostCadenceBehind
                ? max(minimumReductionRatio, min(0.92, cadenceRatio * 1.10))
                : 0.92
            let reductionRatio = min(0.92, max(minimumReductionRatio, min(budgetRatio * 1.05, cadenceScale)))
            let minimumFloor = max(1, encoderThroughputMinimumBitrateFloorBps)
            let targetBitrate = max(
                minimumFloor,
                Int((Double(currentBitrate) * reductionRatio).rounded(.down))
            )
            guard targetBitrate < currentBitrate else { return }

            realtimePressureState = .pressured
            realtimePressureReason = "encoder-throughput"
            realtimeLastEncoderThroughputAdjustmentTime = now
            if mediaPathProfile.usesLocalBulkTransportPolicy {
                let policy = activeFrameFreshnessPolicy
                let sourceStill = sourceIsStill(now: now, policy: policy)
                let severe = encoderBacklogMs >= frameBudgetMs * 4.0 ||
                    averageEncodeMs >= frameBudgetMs * 1.75 ||
                    (captureFPS > 0 && encodedFPS < captureFPS * 0.55)
                if let decision = adaptivePFrameController.recordEncoderTimingPressure(
                    severe: severe,
                    cutScale: reductionRatio,
                    reason: mediaPathProfile.usesLocalBulkTransportPolicy && !sourceStill ? .encodedFrame : .encoderLag,
                    currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
                    requestedTargetBitrateBps: requestedTargetBitrate,
                    startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
                    minimumBitrateFloorBps: encoderThroughputMinimumBitrateFloorBps,
                    currentFrameRate: currentFrameRate,
                    maxPayloadSize: maxPayloadSize,
                    currentQuality: activeQuality,
                    qualityFloor: adaptiveMotionBudgetQualityFloor(sourceStill: sourceStill),
                    steadyQualityCeiling: configuredQualityCeiling,
                    latencyMode: latencyMode,
                    mediaPathProfile: mediaPathProfile,
                    receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs,
                    awdlQualityReductionAllowed: currentAwdlQualityReductionAllowed(now: now),
                    now: now
                ) {
                    await applyAdaptiveRuntimeDecision(decision, now: now)
                }
            } else {
                await applyAdaptiveRuntimeDecision(
                    encoderThroughputBudgetDecision(
                        targetBitrateBps: targetBitrate,
                        state: .pressured,
                        reason: .encoderLag,
                        now: now
                    ),
                    now: now
                )
            }
            let budgetText = frameBudgetMs.formatted(.number.precision(.fractionLength(1)))
            let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
            let backlogText = encoderBacklogMs.formatted(.number.precision(.fractionLength(1)))
            let thresholdText = backlogThresholdMs.formatted(.number.precision(.fractionLength(1)))
            let baselineText: String = if let encoderBaselineMs {
                "\(encoderBaselineMs.formatted(.number.precision(.fractionLength(1))))ms"
            } else {
                "none"
            }
            let pressureThresholdText = encodePressureThresholdMs
                .formatted(.number.precision(.fractionLength(1)))
            let actionText = mediaPathProfile.usesLocalBulkTransportPolicy ? "quality cut" : "budget cut"
            let appliedTargetBitrate = mediaPathProfile.usesLocalBulkTransportPolicy ? currentBitrate : targetBitrate
            MirageLogger.metrics(
                "Encoder throughput \(actionText) stream \(streamID): " +
                    "encodeAvg=\(avgText)ms baseline=\(baselineText) budget=\(budgetText)ms " +
                    "pressureThreshold=\(pressureThresholdText)ms backlog=\(backlogText)ms " +
                    "backlogThreshold=\(thresholdText)ms " +
                    "target=\(currentBitrate)->\(appliedTargetBitrate) captureFPS=\(Self.formattedFPS(captureFPS)) " +
                    "attemptFPS=\(Self.formattedFPS(encodeAttemptFPS)) " +
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
        guard now - realtimeLastEncoderThroughputAdjustmentTime >= 0.45 else { return }

        let policy = activeFrameFreshnessPolicy
        let sourceStill = sourceIsStill(now: now, policy: policy)
        let inputActive = inputIsActive(now: now, policy: policy)
        let stillQualityRaise = sourceStill && !inputActive
        let raiseRatio = stillQualityRaise ? 1.75 : 1.45
        let raiseStep = stillQualityRaise ? 48_000_000 : 24_000_000
        let targetBitrate = min(
            ceilingBitrate,
            max(currentBitrate + raiseStep, Int((Double(currentBitrate) * raiseRatio).rounded(.up)))
        )
        guard targetBitrate > currentBitrate else { return }

        realtimePressureState = .observing
        realtimePressureReason = HostAdaptivePFrameController.Reason.healthy.rawValue
        realtimeLastEncoderThroughputAdjustmentTime = now
        await applyAdaptiveRuntimeDecision(
            encoderThroughputBudgetDecision(
                targetBitrateBps: targetBitrate,
                state: .observing,
                reason: .healthy,
                now: now
            ),
            now: now
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

    private func encoderThroughputBudgetDecision(
        targetBitrateBps: Int,
        state: HostAdaptivePFrameController.PressureState,
        reason: HostAdaptivePFrameController.Reason,
        now: CFAbsoluteTime
    ) -> HostFrameBudgetDecision {
        let width = Int(max(1, currentEncodedSize.width.rounded()))
        let height = Int(max(1, currentEncodedSize.height.rounded()))
        let qualities = MirageBitrateQualityMapper.derivedQualities(
            targetBitrateBps: max(1, targetBitrateBps),
            width: width,
            height: height,
            frameRate: currentFrameRate
        )
        let qualityCeiling = min(compressionQualityCeiling, max(qualities.frameQuality, qualityFloor))
        let targetWireBytes = max(
            1,
            Int((Double(max(1, targetBitrateBps)) / 8.0 / Double(max(1, currentFrameRate))).rounded(.down))
        )
        return HostFrameBudgetDecision(
            targetBitrateBps: targetBitrateBps,
            maxFrameBytes: targetWireBytes,
            maxWireBytes: targetWireBytes,
            maxPacketCount: max(1, Int(ceil(Double(targetWireBytes) / Double(max(1, maxPayloadSize))))),
            quality: min(qualityCeiling, qualities.frameQuality),
            qualityCeiling: qualityCeiling,
            keyframeQuality: min(qualityCeiling, max(qualities.keyframeQuality, qualities.frameQuality)),
            sendDeadline: now + 1.0 / Double(max(1, currentFrameRate)),
            state: state,
            reason: reason
        )
    }

    func applyPerFrameEncoderTimingPressureIfNeeded(
        _ timing: VideoEncoder.EncodedFrameTiming,
        isKeyframe: Bool,
        now: CFAbsoluteTime
    ) async {
        guard !isKeyframe,
              runtimeQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy,
              encoderConfig.codec != .proRes4444,
              currentFrameRate > 0,
              isRunning else {
            return
        }
        guard encoderCatchUpQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy else {
            return
        }

        let frameBudgetMs = runtimeQualityFrameBudgetMs()
        let thresholds = perFrameEncoderTimingThresholds(frameBudgetMs: frameBudgetMs)
        let encodeMs = max(0, timing.encodeDurationMs)
        let captureToCallbackMs = max(0, timing.captureToCallbackMs)
        let encodeBehind = encodeMs >= thresholds.encodePressureMs
        let pipelineBehind = captureToCallbackMs >= thresholds.pipelinePressureMs
        guard encodeBehind || pipelineBehind else { return }

        let policy = activeFrameFreshnessPolicy
        let sourceStill = sourceIsStill(now: now, policy: policy)
        let inputActive = inputIsActive(now: now, policy: policy)
        let stillLowMotionFrame = sourceStill &&
            !inputActive &&
            (timing.captureIsIdleFrame || timing.captureDirtyPercentage <= 0.5)
        if stillLowMotionFrame {
            let severeStillEncodeBehind = encodeMs >= thresholds.encodePressureMs * 1.35
            let severeStillPipelineBehind = captureToCallbackMs >= thresholds.pipelinePressureMs * 1.20
            guard severeStillEncodeBehind || severeStillPipelineBehind else { return }
        }
        let receiverAllowsLocalAdmission = receiverFrameBudgetAllowsLocalAdmission(now: now)
        let senderIsHealthy = await senderFrameBudgetIsHealthy(now: now)
        if !mediaPathProfile.usesAwdlRadioPolicy,
           pipelineBehind,
           !encodeBehind,
           receiverAllowsLocalAdmission,
           senderIsHealthy,
           worstEncodeStartCaptureAgeMs < thresholds.pipelinePressureMs {
            return
        }
        if isStartupTransportProtectionActive(now: now),
           !mediaPathProfile.usesAwdlRadioPolicy,
           receiverAllowsLocalAdmission,
           senderIsHealthy {
            let severeStartupEncodeBehind = encodeMs >= thresholds.encodePressureMs * 1.35
            let severeStartupPipelineBehind = captureToCallbackMs >= max(
                thresholds.pipelinePressureMs * 3.0,
                120.0
            )
            guard severeStartupEncodeBehind || severeStartupPipelineBehind else { return }
        }
        if !mediaPathProfile.usesAwdlRadioPolicy,
           encodeBehind,
           !pipelineBehind,
           encodeMs < thresholds.encodePressureMs * 1.08,
           captureToCallbackMs < thresholds.pipelinePressureMs * 0.75,
           receiverAllowsLocalAdmission,
           senderIsHealthy {
            return
        }

        if mediaPathProfile.usesAwdlRadioPolicy,
           (!runtimeQualityAdjustmentEnabled || !currentAwdlFrameBudgetReductionAllowed(now: now)) {
            realtimePressureState = .pressured
            realtimePressureReason = HostAdaptivePFrameController.Reason.encoderLag.rawValue
            let applied = await applyAwdlHostStructuralAdaptationIfNeeded(
                reason: HostAdaptivePFrameController.Reason.encoderLag.rawValue,
                averageEncodeMs: encodeMs,
                frameBudgetMs: frameBudgetMs,
                at: now
            )
            logPerFrameEncoderTimingPressureIfNeeded(
                timing: timing,
                frameBudgetMs: frameBudgetMs,
                encodePressureMs: thresholds.encodePressureMs,
                pipelinePressureMs: thresholds.pipelinePressureMs,
                cutScale: nil,
                structuralAdaptationApplied: applied,
                now: now
            )
            return
        }

        let encodeCutScale = encodeBehind
            ? frameBudgetMs / max(1, encodeMs) * 1.05
            : 1.0
        let pipelineCutScale = pipelineBehind
            ? thresholds.pipelinePressureMs / max(1, captureToCallbackMs) * 0.92
            : 1.0
        let cutScale = min(
            0.92,
            max(thresholds.minimumCutScale, min(encodeCutScale, pipelineCutScale))
        )
        let severe = encodeMs >= thresholds.encodePressureMs * 1.75 ||
            captureToCallbackMs >= thresholds.pipelinePressureMs * 1.55
        let decision = adaptivePFrameController.recordEncoderTimingPressure(
            severe: severe,
            cutScale: cutScale,
            reason: mediaPathProfile.usesLocalBulkTransportPolicy && !sourceStill ? .encodedFrame : .encoderLag,
            currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            requestedTargetBitrateBps: requestedTargetBitrate,
            startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
            minimumBitrateFloorBps: encoderThroughputMinimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: activeQuality,
            qualityFloor: adaptiveMotionBudgetQualityFloor(sourceStill: sourceStill),
            steadyQualityCeiling: configuredQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs,
            awdlQualityReductionAllowed: currentAwdlQualityReductionAllowed(now: now),
            now: now
        )
        guard let decision else { return }
        await applyAdaptiveRuntimeDecision(decision, now: now)
        logPerFrameEncoderTimingPressureIfNeeded(
            timing: timing,
            frameBudgetMs: frameBudgetMs,
            encodePressureMs: thresholds.encodePressureMs,
            pipelinePressureMs: thresholds.pipelinePressureMs,
            cutScale: cutScale,
            structuralAdaptationApplied: nil,
            now: now
        )
    }

    private func perFrameEncoderTimingThresholds(
        frameBudgetMs: Double
    ) -> (encodePressureMs: Double, pipelinePressureMs: Double, minimumCutScale: Double) {
        let encodePressureScale: Double
        let pipelinePressureScale: Double
        let minimumCutScale: Double
        switch latencyMode {
        case .lowestLatency:
            encodePressureScale = 1.05
            pipelinePressureScale = 1.75
            minimumCutScale = 0.68
        case .balanced:
            encodePressureScale = 1.18
            pipelinePressureScale = 3.0
            minimumCutScale = 0.74
        case .smoothest:
            encodePressureScale = 1.45
            pipelinePressureScale = 6.0
            minimumCutScale = 0.82
        }
        return (
            encodePressureMs: max(frameBudgetMs * encodePressureScale, frameBudgetMs + 2.0),
            pipelinePressureMs: max(frameBudgetMs * pipelinePressureScale, frameBudgetMs + 8.0),
            minimumCutScale: minimumCutScale
        )
    }

    private func logPerFrameEncoderTimingPressureIfNeeded(
        timing: VideoEncoder.EncodedFrameTiming,
        frameBudgetMs: Double,
        encodePressureMs: Double,
        pipelinePressureMs: Double,
        cutScale: Double?,
        structuralAdaptationApplied: Bool?,
        now: CFAbsoluteTime
    ) {
        guard now - encodedFrameQualityLastLogTime >= 0.5 else { return }
        encodedFrameQualityLastLogTime = now
        let cutText = cutScale.map { ($0 * 100).formatted(.number.precision(.fractionLength(0))) + "%" } ?? "gated"
        let structuralText = structuralAdaptationApplied.map { " structural=\($0)" } ?? ""
        MirageLogger.metrics(
            "event=per_frame_encoder_lag stream=\(streamID) frame=\(timing.frameNumber) " +
                "encodeMs=\(timing.encodeDurationMs.formatted(.number.precision(.fractionLength(1)))) " +
                "captureToCallbackMs=\(timing.captureToCallbackMs.formatted(.number.precision(.fractionLength(1)))) " +
                "budgetMs=\(frameBudgetMs.formatted(.number.precision(.fractionLength(1)))) " +
                "encodeThresholdMs=\(encodePressureMs.formatted(.number.precision(.fractionLength(1)))) " +
                "pipelineThresholdMs=\(pipelinePressureMs.formatted(.number.precision(.fractionLength(1)))) " +
                "cut=\(cutText)\(structuralText) dirty=\(timing.captureDirtyPercentage) " +
                "idle=\(timing.captureIsIdleFrame)"
        )
    }

    /// Clamps the frame budget back to proven realtime capacity when meaningful
    /// motion resumes after a still period. Idle screens ramp the budget freely
    /// (still frames are tiny), so without this the first motion burst encodes
    /// against a target the path may never have cleared at realtime deadlines.
    func applyMotionOnsetBudgetClampIfNeeded(
        isIdleFrame: Bool,
        dirtyPercentage: Float,
        now: CFAbsoluteTime
    ) async {
        guard !isIdleFrame, dirtyPercentage > Self.lowMotionRampDirtyPercentage else { return }
        let previousMotionTime = lastMotionFrameEncodeTime
        lastMotionFrameEncodeTime = now
        guard runtimeQualityAdjustmentEnabled,
              encoderConfig.codec != .proRes4444,
              !isStartupTransportProtectionActive(now: now),
              previousMotionTime > 0 else {
            return
        }
        let policy = activeFrameFreshnessPolicy
        let stillGap = max(policy.stillContentWindow * 2.0, 0.75)
        guard now - previousMotionTime >= stillGap else { return }
        let decision = adaptivePFrameController.prepareForMotionOnset(
            currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            requestedTargetBitrateBps: requestedTargetBitrate,
            startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
            minimumBitrateFloorBps: realtimeMinimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: activeQuality,
            qualityFloor: adaptiveMotionBudgetQualityFloor(sourceStill: false),
            steadyQualityCeiling: configuredQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs,
            now: now
        )
        guard let decision else { return }
        await applyAdaptiveRuntimeDecision(decision, now: now)
        MirageLogger.stream(
            "Motion onset clamped stream \(streamID) budget to "
                + "\(decision.targetBitrateBps)bps quality=\(decision.quality) "
                + "(stillGap=\(Int((now - previousMotionTime) * 1000))ms dirty=\(dirtyPercentage))"
        )
    }

    func applyPreEncodeEncoderBacklogPressureIfNeeded(
        droppedFrameCount: Int,
        encoderLag: HostCaptureAdmissionPolicy.EncoderLagSnapshot,
        now: CFAbsoluteTime
    ) async {
        guard droppedFrameCount > 0,
              runtimeQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy,
              encoderCatchUpQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy,
              encoderConfig.codec != .proRes4444,
              currentFrameRate > 0,
              isRunning,
              HostCaptureAdmissionPolicy.isEncoderLagging(encoderLag, latencyMode: latencyMode) else {
            return
        }

        let frameBudgetMs = runtimeQualityFrameBudgetMs()
        let backlogMs = HostCaptureAdmissionPolicy.estimatedPreEncodeBacklogMs(
            pendingFrameCount: droppedFrameCount,
            encoderLag: encoderLag
        )
        let thresholds = perFrameEncoderTimingThresholds(frameBudgetMs: frameBudgetMs)
        guard encoderLag.averageEncodeMs >= thresholds.encodePressureMs ||
            backlogMs >= thresholds.pipelinePressureMs else {
            return
        }
        if mediaPathProfile.usesAwdlRadioPolicy,
           (!runtimeQualityAdjustmentEnabled || !currentAwdlFrameBudgetReductionAllowed(now: now)) {
            realtimePressureState = .pressured
            realtimePressureReason = HostAdaptivePFrameController.Reason.encoderLag.rawValue
            let applied = await applyAwdlHostStructuralAdaptationIfNeeded(
                reason: HostAdaptivePFrameController.Reason.encoderLag.rawValue,
                averageEncodeMs: encoderLag.averageEncodeMs,
                frameBudgetMs: frameBudgetMs,
                at: now
            )
            logPreEncodeEncoderBacklogPressureIfNeeded(
                droppedFrameCount: droppedFrameCount,
                encoderLag: encoderLag,
                backlogMs: backlogMs,
                frameBudgetMs: frameBudgetMs,
                cutScale: nil,
                structuralAdaptationApplied: applied,
                now: now
            )
            return
        }

        let pressureBasisMs = max(encoderLag.averageEncodeMs, backlogMs)
        let cutScale = min(
            0.92,
            max(0.64, frameBudgetMs / max(1, pressureBasisMs) * 1.15)
        )
        let severe = droppedFrameCount > 1 ||
            backlogMs >= frameBudgetMs * 3 ||
            encoderLag.averageEncodeMs >= frameBudgetMs * 1.75
        let policy = activeFrameFreshnessPolicy
        let sourceStill = sourceIsStill(now: now, policy: policy)
        let decision = adaptivePFrameController.recordEncoderTimingPressure(
            severe: severe,
            cutScale: cutScale,
            reason: mediaPathProfile.usesLocalBulkTransportPolicy && !sourceStill ? .encodedFrame : .encoderLag,
            currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            requestedTargetBitrateBps: requestedTargetBitrate,
            startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
            minimumBitrateFloorBps: encoderThroughputMinimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: activeQuality,
            qualityFloor: adaptiveMotionBudgetQualityFloor(sourceStill: sourceStill),
            steadyQualityCeiling: configuredQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs,
            awdlQualityReductionAllowed: currentAwdlQualityReductionAllowed(now: now),
            now: now
        )
        guard let decision else { return }
        await applyAdaptiveRuntimeDecision(decision, now: now)
        logPreEncodeEncoderBacklogPressureIfNeeded(
            droppedFrameCount: droppedFrameCount,
            encoderLag: encoderLag,
            backlogMs: backlogMs,
            frameBudgetMs: frameBudgetMs,
            cutScale: cutScale,
            structuralAdaptationApplied: nil,
            now: now
        )
    }

    private func logPreEncodeEncoderBacklogPressureIfNeeded(
        droppedFrameCount: Int,
        encoderLag: HostCaptureAdmissionPolicy.EncoderLagSnapshot,
        backlogMs: Double,
        frameBudgetMs: Double,
        cutScale: Double?,
        structuralAdaptationApplied: Bool?,
        now: CFAbsoluteTime
    ) {
        guard now - encodedFrameQualityLastLogTime >= 0.5 else { return }
        encodedFrameQualityLastLogTime = now
        let cutText = cutScale.map { ($0 * 100).formatted(.number.precision(.fractionLength(0))) + "%" } ?? "gated"
        let structuralText = structuralAdaptationApplied.map { " structural=\($0)" } ?? ""
        MirageLogger.metrics(
            "event=pre_encode_encoder_lag stream=\(streamID) dropped=\(droppedFrameCount) " +
                "encodeAvgMs=\(encoderLag.averageEncodeMs.formatted(.number.precision(.fractionLength(1)))) " +
                "inFlight=\(encoderLag.inFlightCount) backlogMs=\(backlogMs.formatted(.number.precision(.fractionLength(1)))) " +
                "budgetMs=\(frameBudgetMs.formatted(.number.precision(.fractionLength(1)))) " +
                "cut=\(cutText)\(structuralText)"
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
        encodedAt now: CFAbsoluteTime,
        timing: VideoEncoder.EncodedFrameTiming? = nil
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
        let inputActive = inputIsActiveForEncodedFrame(
            now: now,
            timing: timing,
            policy: freshnessPolicy
        )
        let sourceStill = sourceIsStillForEncodedFrame(
            now: now,
            timing: timing,
            policy: freshnessPolicy
        )
        let senderTelemetry = await packetSender?.telemetrySnapshot
        let senderHealthy = await senderFrameBudgetIsHealthy(now: now)
        let pressureSnapshot = adaptiveTransportPressureSnapshot(
            senderTelemetry: senderTelemetry,
            now: now
        )
        let encodedFrameBudgetReductionActionable =
            adaptiveFrameCoordinator.transportPressureIsActionable(pressureSnapshot)
        let decision = adaptivePFrameController.evaluateEncodedFrame(
            byteCount: byteCount,
            wireBytes: wireBytes,
            packetCount: packetCount,
            isKeyframe: isKeyframe,
            receiverHealthy: receiverFrameBudgetAllowsLocalAdmission(now: now),
            senderHealthy: senderHealthy,
            inputActive: inputActive,
            sourceStill: sourceStill,
            currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            requestedTargetBitrateBps: requestedTargetBitrate,
            startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
            minimumBitrateFloorBps: realtimeMinimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: activeQuality,
            qualityFloor: adaptiveMotionBudgetQualityFloor(sourceStill: sourceStill),
            steadyQualityCeiling: configuredQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs,
            awdlQualityReductionAllowed: currentAwdlQualityReductionAllowed(),
            budgetReductionActionable: encodedFrameBudgetReductionActionable,
            contentComplexityReductionActionable: mediaPathProfile.usesLocalBulkTransportPolicy && !sourceStill,
            deliveryMode: deliveryModeForEncodedFrame(
                now: now,
                timing: timing,
                policy: freshnessPolicy
            ),
            encodedSize: currentEncodedSize,
            queuedBytesAhead: packetSender?.queuedByteCount ?? 0,
            startupProtectionActive: isStartupTransportProtectionActive(now: now),
            now: now
        )
        if !isKeyframe,
           awdlEncodedPFrameNeedsStructuralAdaptation(decision) {
            await applyAwdlHostStructuralAdaptationIfNeeded(
                reason: "encoded-frame-oversize",
                at: now
            )
        }
        let returnedDecision = decision
        if !isKeyframe, let budgetDecision = returnedDecision.budgetDecision {
            await applyAdaptiveRuntimeDecision(budgetDecision, now: now)
        }
        if !isKeyframe {
            await noteMotionFloorSaturationIfNeeded(
                returnedDecision,
                wireBytes: wireBytes,
                packetCount: packetCount,
                now: now
            )
        }
        return returnedDecision
    }

    private func noteMotionFloorSaturationIfNeeded(
        _ decision: HostEncodedFrameAdmissionDecision,
        wireBytes: Int,
        packetCount: Int,
        now: CFAbsoluteTime
    ) async {
        guard decision.motionFloorSaturated,
              runtimeQualityAdjustmentEnabled,
              mediaPathProfile.usesLocalBulkTransportPolicy,
              encoderConfig.codec != .proRes4444 else {
            return
        }
        let policy = activeFrameFreshnessPolicy
        let inputActive = inputIsActive(now: now, policy: policy)
        let intervalMs = 1_000.0 / Double(max(1, currentFrameRate)) * 2.0
        let admissionDecision = HostTransportFrameAdmissionPolicy.Decision(
            admitsFrame: true,
            mode: .softThrottle,
            reason: HostAdaptivePFrameController.Reason.encodedFrame.rawValue,
            evidence: "encoded-frame:motion-floor-saturated",
            minimumFrameIntervalMs: intervalMs,
            activeHoldMs: 650
        )
        if !inputActive {
            transportAdmissionPressureState.noteCadencePressure(
                admissionDecision,
                holdSeconds: 0.65,
                now: now
            )
        }
        streamQualityGovernor.recordMotionFloorSaturation(
            contract: currentStreamQualityContract(),
            summary: "wireBytes=\(wireBytes) packets=\(packetCount)",
            inputActive: inputActive,
            now: now
        )
        MirageLogger.metrics(
            "event=motion_floor_saturated stream=\(streamID) " +
                "wireBytes=\(wireBytes) packets=\(packetCount) " +
                "quality=\(activeQuality.formatted(.number.precision(.fractionLength(2)))) " +
                "target=\(currentTargetBitrateBps ?? encoderConfig.bitrate ?? 0) " +
                "inputActive=\(inputActive) cadencePressureArmed=\(!inputActive)"
        )
        if !inputActive {
            await applySustainedTransportAdmissionPressureIfNeeded(now: now)
        }
    }

    func shouldSkipPFrameForPreEncodeBudgetAdmission(
        frame: CapturedFrame,
        forceKeyframe: Bool,
        admitsStillQualityProbe: Bool,
        now: CFAbsoluteTime
    ) async -> Bool {
        guard !forceKeyframe,
              !admitsStillQualityProbe,
              !frame.info.isIdleFrame,
              runtimeQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy else {
            return false
        }

        let policy = activeFrameFreshnessPolicy
        let inputActive = inputIsActive(now: now, policy: policy)
        let sourceStill = sourceIsStill(now: now, policy: policy)
        let senderTelemetry = await packetSender?.telemetrySnapshot
        let senderHealthy = await senderFrameBudgetIsHealthy(now: now)
        let pressureSnapshot = adaptiveTransportPressureSnapshot(
            senderTelemetry: senderTelemetry,
            now: now
        )
        let decision = adaptivePFrameController.evaluatePreEncodePFrame(
            dirtyPercentage: frame.info.dirtyPercentage,
            inputActive: inputActive,
            sourceStill: sourceStill,
            receiverHealthy: receiverFrameBudgetAllowsLocalAdmission(now: now),
            receiverPressureActionable: adaptiveFrameCoordinator.receiverPressureIsActionable(pressureSnapshot),
            senderHealthy: senderHealthy,
            queuedBytesAhead: senderTelemetry?.queuedBytes ?? packetSender?.queuedByteCount ?? 0,
            unstartedPFrameCount: senderTelemetry?.unstartedPFrameCount ?? 0,
            receiverReassemblyBacklogFrames: receiverReassemblyBacklogFrames,
            receiverReassemblyBacklogBytes: receiverReassemblyBacklogBytes,
            currentBitrateBps: currentTargetBitrateBps ?? encoderConfig.bitrate,
            requestedTargetBitrateBps: requestedTargetBitrate,
            startupCeilingBps: bitrateAdaptationCeiling ?? startupBitrate,
            minimumBitrateFloorBps: realtimeMinimumBitrateFloorBps,
            currentFrameRate: currentFrameRate,
            maxPayloadSize: maxPayloadSize,
            currentQuality: activeQuality,
            qualityFloor: adaptiveMotionBudgetQualityFloor(sourceStill: sourceStill),
            steadyQualityCeiling: configuredQualityCeiling,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile,
            receiverPlayoutDelayTargetMs: receiverPlayoutDelayTargetMs,
            awdlQualityReductionAllowed: currentAwdlQualityReductionAllowed(),
            now: now
        )
        let allowsBudgetReduction = adaptiveFrameCoordinator.allowsPreEncodeBudgetReduction(pressureSnapshot)
        let decisionAllowsMotionReduction = HostAdaptiveFrameCoordinator.pressureReasonIsMotionComplexity(
            decision.reason?.rawValue
        )
        let allowsDecisionBudgetReduction = allowsBudgetReduction || decisionAllowsMotionReduction

        switch decision.admission {
        case .send:
            return false
        case .sendWithFutureQualityDrop:
            guard allowsDecisionBudgetReduction else {
                logPreEncodePFrameAdmissionIfNeeded(decision, action: "send-observe-only", now: now)
                return false
            }
            if let budgetDecision = decision.budgetDecision {
                await applyAdaptiveRuntimeDecision(budgetDecision, now: now)
            }
            logPreEncodePFrameAdmissionIfNeeded(decision, action: "send-quality-drop", now: now)
            return false
        case .skipBeforeEncode:
            let intervalMs = 1_000.0 / Double(max(1, currentFrameRate)) * 2.0
            let reason = decision.reason?.rawValue ?? HostAdaptivePFrameController.Reason.transportBacklog.rawValue
            guard allowsDecisionBudgetReduction,
                  streamQualityGovernor.allowsTransportAdmissionSkip(
                      snapshot: pressureSnapshot,
                      proposedMode: .softThrottle,
                      reason: reason,
                      evidenceLabel: "pre-encode:\(decision.reason?.rawValue ?? "budget")",
                      inputActive: inputActive,
                      contract: currentStreamQualityContract(),
                      now: now
                  ) else {
                logPreEncodePFrameAdmissionIfNeeded(decision, action: "send-observe-only", now: now)
                return false
            }
            if let budgetDecision = decision.budgetDecision {
                await applyAdaptiveRuntimeDecision(budgetDecision, now: now)
            }
            droppedFrameCount += 1
            transportAdmissionSkippedIntervalCount += 1
            let admissionDecision = HostTransportFrameAdmissionPolicy.Decision(
                admitsFrame: false,
                mode: .softThrottle,
                reason: reason,
                evidence: "pre-encode:\(decision.reason?.rawValue ?? "budget")",
                minimumFrameIntervalMs: intervalMs,
                activeHoldMs: 0
            )
            transportAdmissionPressureState.noteSkip(admissionDecision, now: now)
            logPreEncodePFrameAdmissionIfNeeded(decision, action: "skip", now: now)
            await applySustainedTransportAdmissionPressureIfNeeded(now: now)
            return true
        }
    }

    func handleDroppedPFrameForTransportBudget(
        byteCount: Int,
        wireBytes: Int,
        packetCount: Int,
        evaluation: HostEncodedFrameAdmissionDecision,
        encodedAt now: CFAbsoluteTime
    ) async {
        droppedFrameCount += 1
        let isCatastrophicRepair = evaluation.budgetDecision?.reason == .adaptiveRepair
        await applyAwdlHostStructuralAdaptationIfNeeded(
            reason: isCatastrophicRepair ? "encoded-frame-catastrophic-oversize" : "encoded-frame-motion-burst",
            at: now
        )
        startFrameChainRepair(
            reason: isCatastrophicRepair
                ? "transport-p-frame-catastrophic-oversize"
                : "transport-p-frame-motion-burst",
            now: now
        )
        await noteEmergencyKeyframePrepared(using: evaluation.budgetDecision)
        await scheduleEmergencyChainRepairKeyframe(
            reason: isCatastrophicRepair
                ? "Transport P-frame catastrophic oversize"
                : "Transport P-frame motion burst",
            bypassesRecoveryCooldown: true,
            now: now
        )
        logAdaptivePFrameAdmissionIfNeeded(
            frameNumber: nil,
            byteCount: byteCount,
            wireBytes: wireBytes,
            packetCount: packetCount,
            evaluation: evaluation,
            action: isCatastrophicRepair ? "drop-catastrophic-chain-repair" : "drop-motion-burst-chain-repair",
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

    private func inputIsActiveForEncodedFrame(
        now: CFAbsoluteTime,
        timing: VideoEncoder.EncodedFrameTiming?,
        policy: HostFrameFreshnessPolicy
    ) -> Bool {
        if inputIsActive(now: now, policy: policy) { return true }
        guard let timing else { return false }

        let captureTime = now - max(0, timing.captureToCallbackMs) / 1_000.0
        guard lastClientInputTime > 0,
              lastClientInputTime <= captureTime else {
            return false
        }
        return captureTime - lastClientInputTime <= policy.inputActiveWindow
    }

    private func sourceIsStillForEncodedFrame(
        now: CFAbsoluteTime,
        timing: VideoEncoder.EncodedFrameTiming?,
        policy: HostFrameFreshnessPolicy
    ) -> Bool {
        let streamStill = sourceIsStill(now: now, policy: policy)
        guard let timing else { return streamStill }
        if timing.captureIsIdleFrame { return true }
        if timing.captureDirtyPercentage > 0.5 { return false }
        return streamStill
    }

    private func deliveryModeForEncodedFrame(
        now: CFAbsoluteTime,
        timing: VideoEncoder.EncodedFrameTiming?,
        policy: HostFrameFreshnessPolicy
    ) -> HostFrameDeliveryMode {
        motionClassForEncodedFrame(now: now, timing: timing, policy: policy).deliveryMode
    }

    private func motionClassForEncodedFrame(
        now: CFAbsoluteTime,
        timing: VideoEncoder.EncodedFrameTiming?,
        policy: HostFrameFreshnessPolicy
    ) -> EncodedFrameMotionClass {
        guard !inputIsActiveForEncodedFrame(now: now, timing: timing, policy: policy) else {
            lowMotionRampCandidateFrameCount = 0
            return .highMotion
        }
        guard let timing else {
            if sourceIsStill(now: now, policy: policy) {
                lowMotionRampCandidateFrameCount = Self.lowMotionRampRequiredCleanFrames
                return .still
            }
            lowMotionRampCandidateFrameCount = 0
            return .highMotion
        }
        if timing.captureIsIdleFrame || sourceIsStillForEncodedFrame(now: now, timing: timing, policy: policy) {
            lowMotionRampCandidateFrameCount = Self.lowMotionRampRequiredCleanFrames
            return .still
        }
        if timing.captureDirtyPercentage <= Self.mostlyStillDirtyPercentage {
            lowMotionRampCandidateFrameCount = Self.lowMotionRampRequiredCleanFrames
            return .mostlyStill
        }
        if timing.captureDirtyPercentage <= Self.lowMotionRampDirtyPercentage {
            lowMotionRampCandidateFrameCount += 1
        } else {
            lowMotionRampCandidateFrameCount = 0
        }
        return lowMotionRampCandidateFrameCount >= Self.lowMotionRampRequiredCleanFrames ? .lowMotion : .highMotion
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
    ) async -> Bool {
        guard shouldConsiderStillQualityProbe(now: now) else { return false }
        await recoverStillRuntimeQualityIfPossible(now: now, reason: reason)
        shouldAdmitIdleQualityProbeFrame = true
        let shouldScheduleDrain = enqueueSyntheticFrameFromLastCaptureIfNeeded(now: now, reason: reason)
        guard shouldScheduleDrain else {
            return false
        }
        await raiseStillQualityProbeQualityIfPossible(now: now, reason: reason)
        lastStillQualityProbeEncodeTime = now
        scheduleProcessingAfterFrameInboxEnqueue(shouldScheduleDrain)
        MirageLogger.metrics(
            "Still quality probe scheduled for stream \(streamID): reason=\(reason)"
        )
        return true
    }

    private func recoverStillRuntimeQualityIfPossible(
        now: CFAbsoluteTime,
        reason: String
    ) async {
        guard realtimeRuntimeQualityCeiling != nil else { return }
        let policy = activeFrameFreshnessPolicy
        guard sourceIsStill(now: now, policy: policy),
              !inputIsActive(now: now, policy: policy),
              receiverFrameBudgetCanRaiseQuality(now: now),
              await senderFrameBudgetIsHealthy(now: now) else {
            return
        }
        let targetQuality = max(qualityFloor, min(configuredQualityCeiling, qualityCeiling))
        guard streamQualityGovernor.allowsFrameIntentQualityWrite(
            targetQuality: targetQuality,
            currentQuality: activeQuality,
            contract: currentStreamQualityContract(),
            now: now
        ) else {
            return
        }
        realtimeRuntimeQualityCeiling = nil
        let targetBitrate = currentTargetBitrateBps ?? encoderConfig.bitrate ?? requestedTargetBitrate
        guard let targetBitrate else { return }
        await refreshRuntimeQualityTargets(
            for: targetBitrate,
            reason: HostAdaptivePFrameController.Reason.healthy.rawValue
        )
        MirageLogger.metrics(
            "Still quality recovery cleared realtime quality ceiling for stream \(streamID): reason=\(reason)"
        )
    }

    private func raiseStillQualityProbeQualityIfPossible(
        now: CFAbsoluteTime,
        reason: String
    ) async {
        let policy = activeFrameFreshnessPolicy
        guard runtimeQualityAdjustmentEnabled,
              sourceIsStill(now: now, policy: policy),
              !inputIsActive(now: now, policy: policy),
              activeQuality + 0.005 < configuredQualityCeiling,
              stillQualityProbeCanRaiseLocally(policy: policy, now: now),
              stillQualityProbeSenderQueueIsClear() else {
            return
        }
        let targetBitrate = currentTargetBitrateBps ?? encoderConfig.bitrate ?? requestedTargetBitrate
        if let targetBitrate {
            realtimeRuntimeQualityCeiling = nil
            realtimePressureState = .observing
            realtimePressureReason = HostAdaptivePFrameController.Reason.healthy.rawValue
            await refreshRuntimeQualityTargets(
                for: targetBitrate,
                reason: HostAdaptivePFrameController.Reason.healthy.rawValue,
                allowsActiveQualityRaise: false,
                clearsRuntimeQualityCeiling: true
            )
        }

        let previousQuality = activeQuality
        let targetQuality = max(qualityFloor, min(configuredQualityCeiling, qualityCeiling))
        let raisedQuality = targetQuality
        guard raisedQuality > previousQuality + 0.0001 else { return }
        guard streamQualityGovernor.allowsFrameIntentQualityWrite(
            targetQuality: raisedQuality,
            currentQuality: previousQuality,
            contract: currentStreamQualityContract(),
            now: now
        ) else {
            return
        }
        activeQuality = raisedQuality
        await encoder?.updateQuality(activeQuality)
        MirageLogger.metrics(
            "Still quality probe restored quality for stream \(streamID): " +
                "active=\(previousQuality.formatted(.number.precision(.fractionLength(2))))" +
                "->\(activeQuality.formatted(.number.precision(.fractionLength(2)))) " +
                "ceiling=\(targetQuality.formatted(.number.precision(.fractionLength(2)))) " +
                "reason=\(reason)"
        )
    }

    private func stillQualityProbeSenderQueueIsClear() -> Bool {
        (packetSender?.queuedByteCount ?? 0) <= queuePressureBytes
    }

    private func stillQualityProbeCanRaiseLocally(
        policy: HostFrameFreshnessPolicy,
        now: CFAbsoluteTime
    ) -> Bool {
        if frameChainState != .normal { return false }
        if realtimePressureState == .recovery { return false }
        if receiverFrameBudgetLossHoldUntil > now { return false }
        if receiverReassemblyBacklogFrames > policy.stillMaxUnstartedPFrames { return false }
        if receiverReassemblyBacklogBytes > 256 * 1024 { return false }
        if receiverDecodeBacklogFrames > 1 { return false }
        return policy.allowsPresentationFreshness(
            depth: receiverPresentationBacklogFrames,
            latestPresentedFrameAgeMs: receiverLatestPresentedFrameAgeMs,
            inputActive: false,
            sourceStill: true
        )
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
            return false
        }
        if frameChainState != .normal { return false }
        if realtimePressureState == .recovery { return false }
        if receiverReassemblyBacklogFrames > 2 { return false }
        if receiverReassemblyBacklogBytes > 650_000 { return false }
        if receiverDecodeBacklogFrames > 2 { return false }
        if receiverPresentationBacklogFrames > 3 { return false }
        if receiverFrameBudgetLossHoldUntil > now { return false }
        let frameBudgetMs = runtimeQualityFrameBudgetMs()
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
            return receiverUnknownCanUseLocalCleanProbe(now: now)
        }
        if frameChainState != .normal { return false }
        if realtimePressureState == .recovery { return false }
        if receiverFrameBudgetLossHoldUntil > now { return false }
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
        let frameBudgetMs = runtimeQualityFrameBudgetMs()
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

    private func receiverFrameBudgetAllowsLocalAdmission(now: CFAbsoluteTime) -> Bool {
        if isStartupTransportProtectionActive(now: now),
           frameChainState == .normal,
           realtimePressureState != .recovery,
           !transportAdmissionPressureState.isActive(now: now) {
            return true
        }
        return receiverFrameBudgetCanRaiseQuality(now: now)
    }

    private func receiverUnknownCanUseLocalCleanProbe(now: CFAbsoluteTime) -> Bool {
        guard !mediaPathProfile.usesAwdlRadioPolicy else { return false }
        guard frameChainState == .normal,
              realtimePressureState == .observing,
              !transportAdmissionPressureState.isActive(now: now),
              (packetSender?.queuedByteCount ?? 0) <= queuePressureBytes / 2 else {
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
        if receiverFrameBudgetLossHoldUntil > now { return "receiver-loss" }
        if receiverReassemblyBacklogFrames > 2 || receiverReassemblyBacklogBytes > 650_000 { return "reassembly-backlog" }
        let frameBudgetMs = runtimeQualityFrameBudgetMs()
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
        updateSenderFrameBudgetDropWindow(telemetry, now: now)
        if senderFrameBudgetDropHoldUntil > now { return false }
        if telemetry.queuedBytes > queuePressureBytes { return false }
        let frameBudgetMs = runtimeQualityFrameBudgetMs()
        let hardPacerBudgetMs = frameBudgetMs * 3.0
        if telemetry.packetPacerFrameMaxSleepMs > Int(hardPacerBudgetMs.rounded(.up)) { return false }
        return true
    }

    private func updateSenderFrameBudgetDropWindow(
        _ telemetry: StreamPacketSender.TelemetrySnapshot,
        now: CFAbsoluteTime
    ) {
        let observedNewDeadlineDrop = lastObservedSenderLocalDeadlineDrops.map {
            telemetry.senderLocalDeadlineDrops > $0
        } ?? false
        let observedNewHoldDrop = lastObservedNonKeyframeHoldDrops.map {
            telemetry.nonKeyframeHoldDrops > $0
        } ?? false
        lastObservedSenderLocalDeadlineDrops = telemetry.senderLocalDeadlineDrops
        lastObservedNonKeyframeHoldDrops = telemetry.nonKeyframeHoldDrops
        guard observedNewDeadlineDrop || observedNewHoldDrop else { return }
        senderFrameBudgetDropHoldUntil = max(senderFrameBudgetDropHoldUntil, now + 0.85)
    }

    func applyFrameTransportBudgetFeedback(
        _ completion: StreamPacketSender.FrameTransportCompletion,
        now: CFAbsoluteTime
    ) async {
        guard runtimeQualityAdjustmentEnabled || mediaPathProfile.usesAwdlRadioPolicy else { return }
        let deliveryMode = completion.deliveryMode
        if await applyPerFrameTransportCompletionPressureIfNeeded(
            completion,
            deliveryMode: deliveryMode,
            now: now
        ) {
            return
        }
        guard completion.didSend else { return }
        let decision = adaptivePFrameController.recordFrameTransportCompletion(
            frameNumber: UInt64(completion.frameNumber),
            wireBytes: completion.wireBytes,
            packetCount: completion.packetCount,
            isKeyframe: completion.isKeyframe,
            sendCompletionMs: completion.sendCompletionMs,
            timingSource: .localSendCompletion,
            receiverHealthy: receiverFrameBudgetIsHealthy(now: now),
            capacityLearningAllowed: false,
            deliveryMode: deliveryMode,
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
        await applyAdaptiveRuntimeDecision(decision, now: now)
    }

    private func applyPerFrameTransportCompletionPressureIfNeeded(
        _ completion: StreamPacketSender.FrameTransportCompletion,
        deliveryMode: HostFrameDeliveryMode,
        now: CFAbsoluteTime
    ) async -> Bool {
        guard !completion.isKeyframe,
              currentFrameRate > 0,
              completion.sendCompletionMs.isFinite else {
            return false
        }

        let frameBudgetMs = runtimeQualityFrameBudgetMs()
        let thresholds = perFrameTransportCompletionThresholds(frameBudgetMs: frameBudgetMs)
        let sendCompletionMs = max(0, completion.sendCompletionMs)
        let transportDurationMs = max(0, completion.transportDurationMs)
        let drops = completion.queuedUnreliableDropCounts
        if deliveryMode == .lowMotionRamp,
           completion.didSend,
           drops.isEmpty,
           sendCompletionMs <= HostPFrameViabilityController.targetClearMilliseconds(
               deliveryMode: deliveryMode,
               mediaPathProfile: mediaPathProfile
           ),
           transportDurationMs <= HostPFrameViabilityController.targetClearMilliseconds(
               deliveryMode: deliveryMode,
               mediaPathProfile: mediaPathProfile
           ) {
            return false
        }
        let deadlineDropPressureThreshold = UInt64(max(2, (completion.packetCount + 15) / 16))
        let deadlineDropSevereThreshold = UInt64(max(4, (completion.packetCount + 3) / 4))
        let deadlineDropPressure = drops.deadlineExpired >= deadlineDropPressureThreshold ||
            (drops.deadlineExpired > 0 &&
                (sendCompletionMs >= thresholds.pressureMs || transportDurationMs >= thresholds.pressureMs))
        let queueDropPressure = drops.queueLimit > 0
        let otherDropPressure = drops.superseded > 0 ||
            drops.unsupportedTransport > 0 ||
            drops.closed > 0
        let failedWithoutSparseDeadlineDrop = !completion.didSend &&
            (drops.isEmpty || queueDropPressure || otherDropPressure)
        let hasPressure = failedWithoutSparseDeadlineDrop ||
            queueDropPressure ||
            otherDropPressure ||
            deadlineDropPressure ||
            sendCompletionMs >= thresholds.pressureMs ||
            transportDurationMs >= thresholds.pressureMs
        guard hasPressure else { return false }

        let severe = failedWithoutSparseDeadlineDrop ||
            queueDropPressure ||
            otherDropPressure ||
            sendCompletionMs >= thresholds.severeMs ||
            transportDurationMs >= thresholds.severeMs ||
            drops.deadlineExpired >= deadlineDropSevereThreshold
        let localBulkHardDropPressure = failedWithoutSparseDeadlineDrop ||
            queueDropPressure ||
            otherDropPressure ||
            drops.deadlineExpired >= deadlineDropPressureThreshold
        if mediaPathProfile.usesLocalBulkTransportPolicy,
           completion.didSend,
           drops.isEmpty {
            return false
        }
        if isStartupTransportProtectionActive(now: now),
           !mediaPathProfile.usesAwdlRadioPolicy,
           completion.didSend,
           drops.isEmpty,
           !severe {
            return false
        }
        if mediaPathProfile.usesAwdlRadioPolicy,
           (!runtimeQualityAdjustmentEnabled || !currentAwdlFrameBudgetReductionAllowed(now: now)) {
            realtimePressureState = severe ? .severe : .pressured
            realtimePressureReason = HostAdaptivePFrameController.Reason.transportBacklog.rawValue
            let applied = await applyAwdlHostStructuralAdaptationIfNeeded(
                reason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue,
                frameBudgetMs: frameBudgetMs,
                at: now
            )
            logPerFrameTransportCompletionPressureIfNeeded(
                completion,
                frameBudgetMs: frameBudgetMs,
                pressureMs: thresholds.pressureMs,
                severeMs: thresholds.severeMs,
                decision: nil,
                structuralAdaptationApplied: applied,
                now: now
            )
            return true
        }

        let decision = adaptivePFrameController.recordTransportBacklogPressure(
            severe: severe,
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
            awdlQualityReductionAllowed: currentAwdlQualityReductionAllowed(now: now),
            now: now
        )
        guard let decision else { return false }
        await applyAdaptiveRuntimeDecision(
            decision,
            now: now,
            allowsLocalBulkReductionOverride: localBulkHardDropPressure
        )
        logPerFrameTransportCompletionPressureIfNeeded(
            completion,
            frameBudgetMs: frameBudgetMs,
            pressureMs: thresholds.pressureMs,
            severeMs: thresholds.severeMs,
            decision: decision,
            structuralAdaptationApplied: nil,
            now: now
        )
        return true
    }

    private func perFrameTransportCompletionThresholds(
        frameBudgetMs: Double
    ) -> (pressureMs: Double, severeMs: Double) {
        let pressureScale: Double
        let severeScale: Double
        switch latencyMode {
        case .lowestLatency:
            pressureScale = 1.50
            severeScale = 3.0
        case .balanced:
            pressureScale = 2.50
            severeScale = 5.0
        case .smoothest:
            pressureScale = 5.0
            severeScale = 9.0
        }
        let pressureMs = max(frameBudgetMs * pressureScale, frameBudgetMs + 10.0)
        return (
            pressureMs: pressureMs,
            severeMs: max(frameBudgetMs * severeScale, pressureMs * 1.8)
        )
    }

    private func logPerFrameTransportCompletionPressureIfNeeded(
        _ completion: StreamPacketSender.FrameTransportCompletion,
        frameBudgetMs: Double,
        pressureMs: Double,
        severeMs: Double,
        decision: HostFrameBudgetDecision?,
        structuralAdaptationApplied: Bool?,
        now: CFAbsoluteTime
    ) {
        guard now - encodedFrameQualityLastLogTime >= 0.5 else { return }
        encodedFrameQualityLastLogTime = now
        let decisionText = decision.map {
            "state=\($0.state.rawValue) target=\($0.targetBitrateBps) quality=\($0.quality)"
        } ?? "state=gated"
        let structuralText = structuralAdaptationApplied.map { " structural=\($0)" } ?? ""
        MirageLogger.metrics(
            "event=per_frame_transport_pressure stream=\(streamID) frame=\(completion.frameNumber) " +
                "sendMs=\(completion.sendCompletionMs.formatted(.number.precision(.fractionLength(1)))) " +
                "transportMs=\(completion.transportDurationMs.formatted(.number.precision(.fractionLength(1)))) " +
                "budgetMs=\(frameBudgetMs.formatted(.number.precision(.fractionLength(1)))) " +
                "pressureMs=\(pressureMs.formatted(.number.precision(.fractionLength(1)))) " +
                "severeMs=\(severeMs.formatted(.number.precision(.fractionLength(1)))) " +
                "\(decisionText)\(structuralText)"
        )
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

    private func logPreEncodePFrameAdmissionIfNeeded(
        _ decision: HostPreEncodePFrameAdmissionDecision,
        action: String,
        now: CFAbsoluteTime
    ) {
        guard now - encodedFrameQualityLastLogTime >= 0.5 else { return }
        encodedFrameQualityLastLogTime = now
        let predictedKB = (Double(decision.predictedWireBytes) / 1024.0)
            .formatted(.number.precision(.fractionLength(1)))
        let targetKB = (Double(decision.targetWireBytes) / 1024.0)
            .formatted(.number.precision(.fractionLength(1)))
        MirageLogger.metrics(
            "event=pre_encode_p_frame_admission stream=\(streamID) action=\(action) " +
                "predictedWireKB=\(predictedKB) targetWireKB=\(targetKB) " +
                "reason=\(decision.reason?.rawValue ?? "none")"
        )
    }

}
#endif
