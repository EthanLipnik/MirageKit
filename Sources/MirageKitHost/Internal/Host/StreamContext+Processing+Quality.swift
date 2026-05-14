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
                latencyMode: latencyMode
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

    /// Applies runtime encoder quality changes using transport queue pressure.
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

        let averageEncodeMs = await encoder.averageEncodeTimeMs
        let transportPressure = queueBytes > queuePressureBytes
        let sourceCadenceDeficient = virtualDisplaySourceCadenceIsDeficient(queueBytes: queueBytes)
        let allowsRaise = now >= qualityRaiseSuppressionUntil
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
            transportPressure: transportPressure,
            sourceCadenceDeficient: sourceCadenceDeficient,
            allowsRaise: allowsRaise,
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
            let avgText = averageEncodeMs.formatted(.number.precision(.fractionLength(1)))
            MirageLogger.metrics(
                "Quality up to \(qualityText) (encode \(avgText)ms)"
            )
        }
    }

    /// Returns true when virtual display capture cadence is too unstable to raise quality.
    func virtualDisplaySourceCadenceIsDeficient(queueBytes: Int) -> Bool {
        guard captureMode == .display,
              !isAppStream,
              virtualDisplayContext != nil,
              currentFrameRate >= 90 else {
            return false
        }
        guard queueBytes <= max(64 * 1024, queuePressureBytes / 2) else { return false }

        let targetFPS = Double(max(1, currentFrameRate))
        let cadenceFloor = targetFPS * 0.85
        let lowCaptureCadence = [
            lastCaptureIngressFPS,
            lastCaptureFPS,
            lastEncodeAttemptFPS,
        ].contains { value in
            guard let value, value > 0 else { return false }
            return value < cadenceFloor
        }
        let cadence = lastCaptureCadenceMetrics
        let frameBudgetMs = 1000.0 / targetFPS
        let p99Gap = max(
            cadence?.wallClockGapP99Ms ?? 0,
            cadence?.displayTimeGapP99Ms ?? 0,
            cadence?.deliveredFrameGapP99Ms ?? 0
        )
        let worstGap = max(
            cadence?.wallClockGapWorstMs ?? 0,
            cadence?.displayTimeGapWorstMs ?? 0,
            cadence?.deliveredFrameGapWorstMs ?? 0
        )
        let unevenSourceCadence =
            p99Gap >= max(35.0, frameBudgetMs * 2.0) ||
            worstGap >= max(70.0, frameBudgetMs * 4.0) ||
            (cadence?.longFrameGapCount ?? 0) > 0 ||
            cadence?.virtualDisplayTimingSuspect == true

        return lowCaptureCadence || unevenSourceCadence
    }
}
#endif
