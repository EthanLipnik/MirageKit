//
//  StreamController+Lifecycle.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation

extension StreamController {
    // MARK: - Lifecycle

    /// Stop the controller and clean up resources
    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        isRunning = false

        // Stop frame processing - finish stream and cancel task
        stopFrameProcessingPipeline()
        stopMetricsReporting()
        stopFreezeMonitor()
        stopFirstPresentedFrameMonitor()
        onKeyframeNeeded = nil
        onResizeStateChanged = nil
        onFrameDecoded = nil
        onFirstFrameDecoded = nil
        onFirstFramePresented = nil
        onStallEvent = nil
        onRecoveryStatusChanged = nil
        onRecoveryStateChanged = nil
        onTerminalStartupFailure = nil

        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        cancelMemoryBudgetRecoveryTask()
        recoveryKeyframeDispatchTimes.removeAll(keepingCapacity: false)
        lastSoftRecoveryRequestTime = 0
        lastHardRecoveryStartTime = 0
        resetStartupRecoveryTracking()
        latestHostMetricsMessage = nil
        latestHostCadencePressureSample = nil
        latestRenderTelemetrySnapshot = nil
        renderCadenceMissStreak = 0
        lastRenderCadenceMissLogTime = 0
        lastStreamingAnomalyDiagnosticSignature = nil
        lastStreamingAnomalyDiagnosticTime = 0
        lastBackgroundDecodeErrorSignature = nil
        lastBackgroundDecodeErrorLogTime = 0
        consecutiveDecodeErrors = 0
        lastDecodeErrorSignature = nil
        lastDecodeErrorLogTime = 0
        tierPromotionProbeTask?.cancel()
        tierPromotionProbeTask = nil
        resetPostResizeRecoveryTracking(clearResizeRecovery: true)
        MirageRenderStreamStore.shared.clear(for: streamID)
        // Replace decoder callbacks before stopping so a late decoder signal cannot retain or re-enter this controller.
        await decoder.setErrorThresholdHandler {}
        await decoder.setDimensionChangeHandler {}
        await decoder.stopDecoding()
        await GlobalDecodeBudgetController.shared.unregister(streamID: streamID)
    }

    // MARK: - Metrics

    func startMetricsReporting() {
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.metricsDispatchInterval)
                } catch {
                    break
                }
                await dispatchMetrics()
            }
        }
    }

    func stopMetricsReporting() {
        metricsTask?.cancel()
        metricsTask = nil
    }

    private func dispatchMetrics() async {
        let now = currentTime
        let presentationProgressed = syncPresentationProgressFromFrameStore(now: now)
        if presentationProgressed, hasPresentedFirstFrame {
            await clearTransientRecoveryStateAfterPresentationProgress()
        }
        let snapshot = metricsTracker.snapshot(now: now)
        let reassemblerMetrics = reassembler.snapshotMetrics
        let droppedFrames = reassemblerMetrics.droppedFrames + snapshot.queueDroppedFrames
        let decodeBacklogFrames = queuedFrames.count + pendingOrderedFrames.count
        let renderTelemetry = MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        latestRenderTelemetrySnapshot = renderTelemetry
        evaluateRenderCadenceMissTelemetry(
            renderTelemetry: renderTelemetry,
            decodedFPS: snapshot.decodedFPS,
            receivedFPS: snapshot.receivedFPS
        )
        evaluateAdaptiveJitterHold(receivedFPS: snapshot.receivedFPS)
        await evaluateDecodeSubmissionLimit(
            decodedFPS: snapshot.decodedFPS,
            receivedFPS: snapshot.receivedFPS
        )
        let metrics = await ClientFrameMetrics(
            decodedFPS: snapshot.decodedFPS,
            receivedFPS: snapshot.receivedFPS,
            receivedWorstGapMs: snapshot.receivedWorstGapMs,
            receivedFrameIntervalP95Ms: snapshot.receivedFrameIntervalP95Ms,
            receivedFrameIntervalP99Ms: snapshot.receivedFrameIntervalP99Ms,
            droppedFrames: droppedFrames,
            decodeBacklogFrames: decodeBacklogFrames,
            displayTickFPS: renderTelemetry.displayTickFPS,
            submitAttemptFPS: renderTelemetry.submitAttemptFPS,
            layerAcceptedFPS: renderTelemetry.layerAcceptedFPS,
            visibleFrameFPS: renderTelemetry.visibleFrameFPS,
            submittedFPS: renderTelemetry.submittedFPS,
            uniqueSubmittedFPS: renderTelemetry.uniqueSubmittedFPS,
            pendingFrameCount: renderTelemetry.pendingFrameCount,
            pendingFrameAgeMs: renderTelemetry.pendingFrameAgeMs,
            smoothestDisplayDebtMs: renderTelemetry.smoothestDisplayDebtMs,
            smoothestDisplayDebtCapMs: renderTelemetry.smoothestDisplayDebtCapMs,
            smoothestTargetDelayMs: renderTelemetry.smoothestTargetDelayMs,
            overwrittenPendingFrames: renderTelemetry.overwrittenPendingFrames,
            smoothestQueueDrops: renderTelemetry.smoothestQueueDrops,
            smoothestDisplayDebtDrops: renderTelemetry.smoothestDisplayDebtDrops,
            smoothestFifoResetCount: renderTelemetry.smoothestFifoResetCount,
            smoothestDepthDrops: renderTelemetry.smoothestDepthDrops,
            smoothestAgeDrops: renderTelemetry.smoothestAgeDrops,
            smoothestDropsUnder100ms: renderTelemetry.smoothestDropsUnder100ms,
            smoothestDroppedFrameAgeMaxMs: renderTelemetry.smoothestDroppedFrameAgeMaxMs,
            lateFrameDrops: renderTelemetry.lateFrameDrops,
            displayLayerNotReadyCount: renderTelemetry.displayLayerNotReadyCount,
            repeatedFrameCount: renderTelemetry.repeatedFrameCount,
            displayTickNoFrameCount: renderTelemetry.displayTickNoFrameCount,
            missedVSyncCount: renderTelemetry.missedVSyncCount,
            displayTickIntervalP95Ms: renderTelemetry.displayTickIntervalP95Ms,
            displayTickIntervalP99Ms: renderTelemetry.displayTickIntervalP99Ms,
            playoutDelayFrames: renderTelemetry.playoutDelayFrames,
            presentationStallCount: renderTelemetry.presentationStallCount,
            worstPresentationGapMs: renderTelemetry.worstPresentationGapMs,
            frameIntervalP95Ms: renderTelemetry.frameIntervalP95Ms,
            frameIntervalP99Ms: renderTelemetry.frameIntervalP99Ms,
            decodeHealthy: renderTelemetry.decodeHealthy,
            activeJitterHoldMs: adaptiveJitterHoldMs,
            reassemblerPendingFrameCount: reassemblerMetrics.pendingFrameCount,
            reassemblerPendingKeyframeCount: reassemblerMetrics.pendingKeyframeCount,
            reassemblerPendingBytes: reassemblerMetrics.pendingFrameBytes,
            frameBufferPoolRetainedBytes: reassemblerMetrics.frameBufferPoolRetainedBytes,
            reassemblerBudgetEvictions: reassemblerMetrics.budgetEvictions,
            reassemblerIncompleteFrameTimeouts: reassemblerMetrics.incompleteFrameTimeouts,
            reassemblerIncompleteFrameNoProgressTimeouts: reassemblerMetrics.incompleteFrameNoProgressTimeouts,
            reassemblerIncompleteFrameLifetimeTimeouts: reassemblerMetrics.incompleteFrameLifetimeTimeouts,
            reassemblerMissingFragmentTimeouts: reassemblerMetrics.missingFragmentTimeouts,
            reassemblerForwardGapTimeouts: reassemblerMetrics.forwardGapTimeouts,
            reassemblerPFrameCompletionLatencyP50Ms: reassemblerMetrics.pFrameCompletionLatencyP50Ms,
            reassemblerPFrameCompletionLatencyP95Ms: reassemblerMetrics.pFrameCompletionLatencyP95Ms,
            reassemblerPFrameCompletionLatencyMaxMs: reassemblerMetrics.pFrameCompletionLatencyMaxMs,
            reassemblerLatePFrameCompletionCount: reassemblerMetrics.latePFrameCompletionCount,
            reassemblerFECRecoveredFragmentCount: reassemblerMetrics.fecRecoveredFragmentCount,
            decoderOutputPixelFormat: decoder.decodedOutputPixelFormatName,
            usingHardwareDecoder: decoder.currentHardwareDecoderStatus
        )
        let callback = onFrameDecoded
        await MainActor.run {
            callback?(metrics)
        }
    }

    func evaluateDecodeSubmissionLimit(decodedFPS: Double, receivedFPS: Double) async {
        if presentationTier == .passiveSnapshot {
            decodeSubmissionStressStreak = 0
            decodeSubmissionHealthyStreak = 0
            decodeSubmissionBaselineLimit = 1
            decodeSchedulerTargetFPS = max(1, decodeSchedulerTargetFPS)
            lastDecodeSubmissionConstraintWasSourceBound = nil
            lastSourceBoundDiagnosticSignature = nil
            if currentDecodeSubmissionLimit != 1 {
                currentDecodeSubmissionLimit = 1
                await decoder.setDecodeSubmissionLimit(limit: 1, reason: "passive tier fixed submission")
            }
            return
        }

        let targetFPS = max(1, decodeSchedulerTargetFPS)
        let ratio = decodedFPS / Double(targetFPS)
        let stressLimit = min(Self.decodeSubmissionMaximumLimit, decodeSubmissionBaselineLimit + 1)
        let decodeGap = max(0.0, receivedFPS - decodedFPS)
        let sourceBound = receivedFPS > 0 && decodeGap <= Self.decodeSubmissionSourceBoundGapFPS
        let decodeBound = receivedFPS > 0 && decodeGap >= Self.decodeSubmissionDecodeBoundGapFPS
        let hostCadencePressure = hostCadencePressureDiagnostic(sample: latestHostCadencePressureSample)

        if ratio < Self.decodeSubmissionStressThreshold {
            if decodeBound {
                if lastDecodeSubmissionConstraintWasSourceBound != false {
                    await maybeLogStreamingAnomalyDiagnostic(
                        trigger: "decode-submission",
                        decodedFPS: decodedFPS,
                        receivedFPS: receivedFPS
                    )
                }
                lastDecodeSubmissionConstraintWasSourceBound = false
                lastSourceBoundDiagnosticSignature = nil
                decodeSubmissionStressStreak += 1
                decodeSubmissionHealthyStreak = 0
            } else {
                let sourceDiagnosticSignature = hostCadencePressure?.kind.rawValue ?? "generic-source-bound"
                if sourceBound,
                   lastDecodeSubmissionConstraintWasSourceBound != true ||
                   lastSourceBoundDiagnosticSignature != sourceDiagnosticSignature {
                    await maybeLogStreamingAnomalyDiagnostic(
                        trigger: "decode-submission",
                        decodedFPS: decodedFPS,
                        receivedFPS: receivedFPS
                    )
                    lastDecodeSubmissionConstraintWasSourceBound = true
                    lastSourceBoundDiagnosticSignature = sourceDiagnosticSignature
                } else if !sourceBound {
                    lastDecodeSubmissionConstraintWasSourceBound = nil
                    lastSourceBoundDiagnosticSignature = nil
                }
                decodeSubmissionStressStreak = 0
                decodeSubmissionHealthyStreak = 0
            }
        } else if ratio >= Self.decodeSubmissionHealthyThreshold {
            decodeSubmissionHealthyStreak += 1
            decodeSubmissionStressStreak = 0
            lastDecodeSubmissionConstraintWasSourceBound = nil
            lastSourceBoundDiagnosticSignature = nil
        } else {
            decodeSubmissionStressStreak = 0
            decodeSubmissionHealthyStreak = 0
            lastDecodeSubmissionConstraintWasSourceBound = nil
            lastSourceBoundDiagnosticSignature = nil
        }

        if currentDecodeSubmissionLimit < stressLimit,
           decodeSubmissionStressStreak >= Self.decodeSubmissionStressWindows {
            decodeSubmissionStressStreak = 0
            currentDecodeSubmissionLimit = stressLimit
            await decoder.setDecodeSubmissionLimit(
                limit: stressLimit,
                reason: "decode stress (decode-bound)"
            )
            return
        }

        if currentDecodeSubmissionLimit > decodeSubmissionBaselineLimit,
           decodeSubmissionHealthyStreak >= Self.decodeSubmissionHealthyWindows {
            decodeSubmissionHealthyStreak = 0
            currentDecodeSubmissionLimit = decodeSubmissionBaselineLimit
            await decoder.setDecodeSubmissionLimit(
                limit: decodeSubmissionBaselineLimit,
                reason: "decode recovered"
            )
        }
    }
}
