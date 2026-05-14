//
//  StreamController+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream controller extensions.
//

import CoreGraphics
import Foundation
import MirageKit

extension StreamController {
    // MARK: - Private Helpers

    func updateHostMetrics(_ metrics: StreamMetricsMessage?) {
        latestHostMetricsMessage = metrics
        latestHostCadencePressureSample = metrics.map(HostCadencePressureDiagnosticSample.init(metrics:))
        if let targetFrameRate = metrics?.targetFrameRate {
            reassembler.setTargetFrameRate(targetFrameRate)
        }
    }

    func handleKeyframeRecoveryAck(_ ack: KeyframeRecoveryAckMessage) {
        recoveryCoordinator.recordHostAck(ack, now: currentTime)
    }

    func maybeLogStreamingAnomalyDiagnostic(
        trigger: String,
        decodedFPS: Double,
        receivedFPS: Double
    ) async {
        guard MirageLogger.isEnabled(.client) else { return }
        guard !shouldSuppressStartupAnomalyDiagnostic() else { return }

        let renderTelemetry = latestRenderTelemetrySnapshot ??
            MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        let frameMetrics = metricsTracker.snapshot(now: currentTime)
        let reassemblerMetrics = reassembler.snapshotMetrics
        let diagnostic = await clientStreamingAnomalyDiagnostic(
            sample: ClientStreamingAnomalySample(
                streamID: streamID,
                trigger: trigger,
                decodedFPS: decodedFPS,
                receivedFPS: receivedFPS,
                receivedWorstGapMs: frameMetrics.receivedWorstGapMs,
                receivedFrameIntervalP95Ms: frameMetrics.receivedFrameIntervalP95Ms,
                receivedFrameIntervalP99Ms: frameMetrics.receivedFrameIntervalP99Ms,
                displayTickFPS: renderTelemetry.displayTickFPS,
                submitAttemptFPS: renderTelemetry.submitAttemptFPS,
                layerAcceptedFPS: renderTelemetry.layerAcceptedFPS,
                presentedFPS: renderTelemetry.presentedFPS,
                submittedFPS: renderTelemetry.submittedFPS,
                uniqueSubmittedFPS: renderTelemetry.uniqueSubmittedFPS,
                pendingFrameCount: renderTelemetry.pendingFrameCount,
                pendingFrameAgeMs: renderTelemetry.pendingFrameAgeMs,
                overwrittenPendingFrames: renderTelemetry.overwrittenPendingFrames,
                smoothestQueueDrops: renderTelemetry.smoothestQueueDrops,
                lateFrameDrops: renderTelemetry.lateFrameDrops,
                coalescedBeforeSubmitCount: renderTelemetry.coalescedBeforeSubmitCount,
                duplicateRemoteTimestampCount: renderTelemetry.duplicateRemoteTimestampCount,
                correctedStreamTimestampCount: renderTelemetry.correctedStreamTimestampCount,
                displayLayerNotReadyCount: renderTelemetry.displayLayerNotReadyCount,
                repeatedFrameCount: renderTelemetry.repeatedFrameCount,
                missedVSyncCount: renderTelemetry.missedVSyncCount,
                displayTickIntervalP95Ms: renderTelemetry.displayTickIntervalP95Ms,
                displayTickIntervalP99Ms: renderTelemetry.displayTickIntervalP99Ms,
                playoutDelayFrames: renderTelemetry.playoutDelayFrames,
                presentationStallCount: renderTelemetry.presentationStallCount,
                worstPresentationGapMs: renderTelemetry.worstPresentationGapMs,
                frameIntervalP95Ms: renderTelemetry.frameIntervalP95Ms,
                frameIntervalP99Ms: renderTelemetry.frameIntervalP99Ms,
                decodeHealthy: renderTelemetry.decodeHealthy,
                decodeSubmissionLimit: currentDecodeSubmissionLimit,
                presentationTier: presentationTier,
                reassemblerPendingFrameCount: reassemblerMetrics.pendingFrameCount,
                reassemblerPendingKeyframeCount: reassemblerMetrics.pendingKeyframeCount,
                reassemblerPendingBytes: reassemblerMetrics.pendingFrameBytes,
                frameBufferPoolRetainedBytes: reassemblerMetrics.frameBufferPoolRetainedBytes,
                reassemblerBudgetEvictions: reassemblerMetrics.budgetEvictions,
                decoderOutputPixelFormat: decoder.decodedOutputPixelFormatName,
                usingHardwareDecoder: decoder.currentHardwareDecoderStatus,
                targetFrameRate: max(1, latestHostMetricsMessage?.targetFrameRate ?? streamCadenceTarget.sourceFPS),
                sourceTargetFrameRate: max(1, streamCadenceTarget.sourceFPS),
                displayTargetFrameRate: max(1, streamCadenceTarget.displayFPS),
                hostMetrics: latestHostMetricsMessage
            )
        )
        let signature = "\(trigger)|\(diagnostic.signature)"
        let now = currentTime
        if signature == lastStreamingAnomalyDiagnosticSignature,
           lastStreamingAnomalyDiagnosticTime > 0,
           now - lastStreamingAnomalyDiagnosticTime < Self.streamingAnomalyLogCooldown {
            return
        }

        lastStreamingAnomalyDiagnosticSignature = signature
        lastStreamingAnomalyDiagnosticTime = now
        MirageLogger.client(diagnostic.message)
    }

    func shouldSuppressStartupAnomalyDiagnostic() -> Bool {
        guard presentationTier == .activeLive else { return false }
        guard hasPresentedFirstFrame else { return true }
        guard latestHostMetricsMessage == nil else { return false }
        let firstPresentationTime = lastPresentedProgressTime
        guard firstPresentationTime > 0 else { return true }
        let sampleWindow = max(
            0.50,
            Self.frameIntervalSeconds(targetFPS: streamCadenceTarget.sourceFPS) * 12.0
        )
        return currentTime - firstPresentationTime < sampleWindow
    }

    func evaluateRenderCadenceMissTelemetry(
        renderTelemetry: RenderTelemetrySnapshot,
        decodedFPS: Double,
        receivedFPS: Double
    ) {
        guard presentationTier == .activeLive, hasPresentedFirstFrame else {
            renderCadenceMissStreak = 0
            return
        }

        let targetFPS = Double(max(1, latestHostMetricsMessage?.targetFrameRate ?? streamCadenceTarget.displayFPS))
        let targetFloor = targetFPS * 0.90
        let sourceFPS = max(decodedFPS, receivedFPS)
        guard sourceFPS >= targetFPS * 0.70,
              renderTelemetry.uniqueSubmittedFPS > 0,
              renderTelemetry.uniqueSubmittedFPS < targetFloor else {
            renderCadenceMissStreak = 0
            return
        }

        renderCadenceMissStreak += 1
        let now = currentTime
        guard renderCadenceMissStreak >= Self.renderCadenceMissSampleThreshold,
              now - lastRenderCadenceMissLogTime >= Self.renderCadenceMissLogCooldown else {
            return
        }

        lastRenderCadenceMissLogTime = now
        MirageLogger.client(
            "Render cadence below target: stream=\(streamID) target=\(Int(targetFPS))fps " +
                "received=\(String(format: "%.1f", receivedFPS))fps decoded=\(String(format: "%.1f", decodedFPS))fps " +
                "displayTick=\(String(format: "%.1f", renderTelemetry.displayTickFPS))fps " +
                "submitAttempt=\(String(format: "%.1f", renderTelemetry.submitAttemptFPS))fps " +
                "layerAccepted=\(String(format: "%.1f", renderTelemetry.layerAcceptedFPS))fps " +
                "uniqueSubmitted=\(String(format: "%.1f", renderTelemetry.uniqueSubmittedFPS))fps " +
                "pending=\(renderTelemetry.pendingFrameCount) pendingAge=\(Int(renderTelemetry.pendingFrameAgeMs.rounded()))ms " +
                "smoothestDrops=\(renderTelemetry.smoothestQueueDrops) " +
                "overwritten=\(renderTelemetry.overwrittenPendingFrames) lateDrops=\(renderTelemetry.lateFrameDrops) " +
                "layerBackpressure=\(renderTelemetry.displayLayerNotReadyCount) " +
                "frameP99=\(Int(renderTelemetry.frameIntervalP99Ms.rounded()))ms " +
                "tickP99=\(Int(renderTelemetry.displayTickIntervalP99Ms.rounded()))ms"
        )
    }

    func setTransportPathKind(_ kind: MirageNetworkPathKind) {
        let awdlActive = awdlExperimentEnabled && kind == .awdl
        guard awdlTransportActive != awdlActive else { return }
        awdlTransportActive = awdlActive
        if !awdlActive {
            adaptiveJitterHoldMs = 0
            adaptiveJitterStressStreak = 0
            adaptiveJitterStableStreak = 0
        }
    }

    func evaluateAdaptiveJitterHold(receivedFPS: Double) {
        guard awdlExperimentEnabled, awdlTransportActive else {
            guard adaptiveJitterHoldMs != 0 ||
                adaptiveJitterStressStreak != 0 ||
                adaptiveJitterStableStreak != 0 else {
                return
            }
            adaptiveJitterHoldMs = 0
            adaptiveJitterStressStreak = 0
            adaptiveJitterStableStreak = 0
            return
        }

        let state = Self.nextAdaptiveJitterState(
            current: AdaptiveJitterState(
                holdMs: adaptiveJitterHoldMs,
                stressStreak: adaptiveJitterStressStreak,
                stableStreak: adaptiveJitterStableStreak
            ),
            receivedFPS: receivedFPS,
            targetFPS: decodeSchedulerTargetFPS
        )
        guard state.holdMs != adaptiveJitterHoldMs ||
            state.stressStreak != adaptiveJitterStressStreak ||
            state.stableStreak != adaptiveJitterStableStreak else {
            return
        }
        adaptiveJitterHoldMs = state.holdMs
        adaptiveJitterStressStreak = state.stressStreak
        adaptiveJitterStableStreak = state.stableStreak
    }

    func setResizeState(_ newState: ResizeState) async {
        guard resizeState != newState else { return }
        resizeState = newState

        Task { @MainActor [weak self] in
            guard let self else { return }
            await onResizeStateChanged?(newState)
        }
    }
}
