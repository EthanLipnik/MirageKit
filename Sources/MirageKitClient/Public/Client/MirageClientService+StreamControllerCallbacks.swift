//
//  MirageClientService+StreamControllerCallbacks.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  StreamController callback wiring.
//

import CoreFoundation
import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    /// Connects a stream controller's decode, presentation, stall, and recovery callbacks to client state.
    func configureCallbacks(
        for controller: StreamController,
        streamID: StreamID
    ) async {
        let videoIngressStore = videoIngressTelemetryStore
        await controller.setCallbacks(
            onKeyframeNeeded: { [weak self] in
                self?.sendKeyframeRequest(for: streamID) ?? false
            },
            onResizeStateChanged: nil,
            onFrameDecoded: { [weak self] metrics in
                guard let self else { return }
                recordVideoIngressMetricsSample(for: streamID, metrics: metrics)
                metricsStore.updateClientMetrics(
                    streamID: streamID,
                    decodedFPS: metrics.decodedFPS,
                    receivedFPS: metrics.receivedFPS,
                    receivedWorstGapMs: metrics.receivedWorstGapMs,
                    receivedFrameIntervalP95Ms: metrics.receivedFrameIntervalP95Ms,
                    receivedFrameIntervalP99Ms: metrics.receivedFrameIntervalP99Ms,
                    droppedFrames: metrics.droppedFrames,
                    reassemblerPendingFrameCount: metrics.reassemblerPendingFrameCount,
                    reassemblerPendingKeyframeCount: metrics.reassemblerPendingKeyframeCount,
                    reassemblerPendingBytes: metrics.reassemblerPendingBytes,
                    frameBufferPoolRetainedBytes: metrics.frameBufferPoolRetainedBytes,
                    reassemblerBudgetEvictions: metrics.reassemblerBudgetEvictions,
                    reassemblerIncompleteFrameTimeouts: metrics.reassemblerIncompleteFrameTimeouts,
                    reassemblerMissingFragmentTimeouts: metrics.reassemblerMissingFragmentTimeouts,
                    displayTickFPS: metrics.displayTickFPS,
                    submitAttemptFPS: metrics.submitAttemptFPS,
                    layerAcceptedFPS: metrics.layerAcceptedFPS,
                    presentedFPS: metrics.presentedFPS,
                    submittedFPS: metrics.submittedFPS,
                    uniqueSubmittedFPS: metrics.uniqueSubmittedFPS,
                    pendingFrameCount: metrics.pendingFrameCount,
                    pendingFrameAgeMs: metrics.pendingFrameAgeMs,
                    overwrittenPendingFrames: metrics.overwrittenPendingFrames,
                    smoothestQueueDrops: metrics.smoothestQueueDrops,
                    lateFrameDrops: metrics.lateFrameDrops,
                    displayLayerNotReadyCount: metrics.displayLayerNotReadyCount,
                    repeatedFrameCount: metrics.repeatedFrameCount,
                    missedVSyncCount: metrics.missedVSyncCount,
                    displayTickIntervalP95Ms: metrics.displayTickIntervalP95Ms,
                    displayTickIntervalP99Ms: metrics.displayTickIntervalP99Ms,
                    playoutDelayFrames: metrics.playoutDelayFrames,
                    presentationStallCount: metrics.presentationStallCount,
                    worstPresentationGapMs: metrics.worstPresentationGapMs,
                    frameIntervalP95Ms: metrics.frameIntervalP95Ms,
                    frameIntervalP99Ms: metrics.frameIntervalP99Ms,
                    decodeHealthy: metrics.decodeHealthy
                )
                metricsStore.updateClientDecoderTelemetry(
                    streamID: streamID,
                    outputPixelFormat: metrics.decoderOutputPixelFormat,
                    usingHardwareDecoder: metrics.usingHardwareDecoder
                )
                if activeJitterHoldMs != metrics.activeJitterHoldMs {
                    activeJitterHoldMs = metrics.activeJitterHoldMs
                }
                sendReceiverMediaFeedback(streamID: streamID, metrics: metrics)
                logAwdlExperimentTelemetryIfNeeded()
            },
            videoIngressMetricsProvider: { streamID in
                videoIngressStore.snapshot(for: streamID)
            },
            onFirstFrameDecoded: { [weak self] in
                self?.sessionStore.markFirstFrameDecoded(for: streamID)
                MirageLogger.signpostEvent(.client, "Startup.FirstFrameDecoded", "stream=\(streamID)")
            },
            onFirstFramePresented: { [weak self] in
                self?.handleStreamFirstFramePresented(streamID: streamID)
                self?.clearStartupAttempt(for: streamID)
                MirageLogger.signpostEvent(.client, "Startup.FirstFramePresented", "stream=\(streamID)")
            },
            onStallEvent: { [weak self] event in
                guard let self else { return }
                stallEvents &+= 1
                inputEventSender.activateTemporaryPointerCoalescing(for: streamID, duration: 1.2)
                handleRuntimeWorkloadSafetyStallEvent(streamID: streamID, event: event)
                logAwdlExperimentTelemetryIfNeeded()
            },
            onRecoveryStatusChanged: { [weak self] status in
                self?.sessionStore.setClientRecoveryStatus(for: streamID, status: status)
                if status == .idle {
                    self?.handleDesktopPresentationReady(streamID: streamID)
                }
            },
            onTerminalStartupFailure: { [weak self] failure in
                Task {
                    await self?.handleTerminalStartupFailure(failure, for: streamID)
                }
            }
        )
    }

    private func recordVideoIngressMetricsSample(
        for streamID: StreamID,
        metrics: StreamController.ClientFrameMetrics
    ) {
        guard let processor = videoPacketIngressProcessors[streamID] else {
            videoIngressTelemetryStore.clear(streamID: streamID)
            MirageRenderStreamStore.shared.recordSmoothestStreamHealth(
                for: streamID,
                healthyForLiveEdge: false,
                requiresHardCushion: true
            )
            return
        }

        let snapshot = processor.snapshot()
        videoIngressTelemetryStore.update(snapshot, for: streamID)
        let currentDropCount = snapshot.stalePacketDropCount + snapshot.overloadPacketDropCount
        let previousDropCount = videoIngressLastDropCountByStream[streamID] ?? currentDropCount
        let ingressDropDelta = currentDropCount >= previousDropCount
            ? currentDropCount - previousDropCount
            : 0
        videoIngressLastDropCountByStream[streamID] = currentDropCount
        let hostTargetFPS = metricsStore.snapshot(for: streamID)?.hostTargetFrameRate ?? 0
        let displayTargetFPS = Int(metrics.displayTickFPS.rounded())
        let targetFPS = hostTargetFPS > 0 ? hostTargetFPS : max(1, displayTargetFPS)
        let health = Self.smoothestLiveEdgeHealth(
            metrics: metrics,
            ingressMetrics: snapshot,
            ingressDropDelta: ingressDropDelta,
            targetFPS: targetFPS
        )
        MirageRenderStreamStore.shared.recordSmoothestStreamHealth(
            for: streamID,
            healthyForLiveEdge: health.healthyForLiveEdge,
            requiresHardCushion: health.requiresHardCushion
        )
    }

    struct SmoothestLiveEdgeHealth: Sendable, Equatable {
        let healthyForLiveEdge: Bool
        let requiresHardCushion: Bool
    }

    nonisolated static func smoothestLiveEdgeHealth(
        metrics: StreamController.ClientFrameMetrics,
        ingressMetrics: ClientVideoIngressMetricsSnapshot,
        ingressDropDelta: UInt64,
        targetFPS: Int
    ) -> SmoothestLiveEdgeHealth {
        let targetFPS = max(1, targetFPS)
        let frameBudgetMs = 1000.0 / Double(targetFPS)
        let reassembledP99LimitMs = max(frameBudgetMs * 2.25, targetFPS >= 90 ? 24.0 : 37.0)
        let batchP99LimitMs = max(frameBudgetMs * 2.0, targetFPS >= 90 ? 20.0 : 34.0)
        let loomGapLimitMs = max(frameBudgetMs * 3.0, targetFPS >= 90 ? 28.0 : 50.0)
        let workerWakeLimitMs = max(frameBudgetMs * 1.25, targetFPS >= 90 ? 12.0 : 22.0)
        let minimumFrameCadence = Double(targetFPS) * 0.85

        let presentationJitterClean = metrics.displayTickNoFrameCount == 0 &&
            metrics.frameArrivedAfterNoFrameTickCount == 0 &&
            metrics.frameArrivalFallbackSubmittedCount == 0 &&
            metrics.missedVSyncCount == 0
        let queueTargetDepth = max(1, metrics.queueTargetDepth)
        let catchUpDropsAreExpected = metrics.smoothestQueueDrops > 0 &&
            metrics.smoothestQueueDrops == metrics.smoothestCatchUpDrops &&
            metrics.pendingFrameCount <= queueTargetDepth &&
            metrics.pendingFrameAgeMs <= frameBudgetMs * 3.0
        let smoothestDropsClean = metrics.smoothestQueueDrops == 0 || catchUpDropsAreExpected
        let renderPolicyClean = smoothestDropsClean &&
            metrics.lateFrameDrops == 0 &&
            metrics.displayLayerNotReadyCount == 0
        let reassembledCadenceClean = metrics.receivedFPS >= minimumFrameCadence &&
            (metrics.receivedFrameIntervalP99Ms == 0 ||
                metrics.receivedFrameIntervalP99Ms <= reassembledP99LimitMs)
        let decodeCadenceClean = metrics.decodeHealthy &&
            metrics.decodedFPS >= minimumFrameCadence
        let ingressClean = ingressMetrics.rawPacketIngressPPS > 0 &&
            ingressMetrics.queuedPacketCount == 0 &&
            ingressMetrics.queueAgeMaxMs <= frameBudgetMs &&
            ingressDropDelta == 0 &&
            ingressMetrics.processorWakeDelayMaxMs <= workerWakeLimitMs &&
            (ingressMetrics.incomingBatchIntervalP99Ms == 0 ||
                ingressMetrics.incomingBatchIntervalP99Ms <= batchP99LimitMs) &&
            (ingressMetrics.loomStreamDeliveryIntervalMaxMs == 0 ||
                ingressMetrics.loomStreamDeliveryIntervalMaxMs <= loomGapLimitMs)

        let healthyForLiveEdge = presentationJitterClean &&
            renderPolicyClean &&
            reassembledCadenceClean &&
            decodeCadenceClean &&
            ingressClean

        let repeatedPresentationJitter = metrics.displayTickNoFrameCount > 1 ||
            metrics.frameArrivedAfterNoFrameTickCount > 1 ||
            metrics.frameArrivalFallbackSubmittedCount > 1 ||
            metrics.missedVSyncCount > 0
        let ingressBacklogOrDrop = ingressDropDelta > 0 ||
            ingressMetrics.queuedPacketCount > 0 ||
            ingressMetrics.queueAgeMaxMs > frameBudgetMs * 2.0 ||
            ingressMetrics.processorWakeDelayMaxMs > workerWakeLimitMs * 2.0
        let sustainedClientBacklog = metrics.pendingFrameCount > queueTargetDepth
        let requiresHardCushion = repeatedPresentationJitter ||
            !decodeCadenceClean ||
            metrics.displayLayerNotReadyCount > 0 ||
            ingressBacklogOrDrop ||
            sustainedClientBacklog

        return SmoothestLiveEdgeHealth(
            healthyForLiveEdge: healthyForLiveEdge,
            requiresHardCushion: requiresHardCushion
        )
    }

    private func sendReceiverMediaFeedback(
        streamID: StreamID,
        metrics: StreamController.ClientFrameMetrics
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        if let lastSendTime = receiverMediaFeedbackLastSendTime[streamID],
           now - lastSendTime < receiverMediaFeedbackInterval {
            return
        }
        receiverMediaFeedbackLastSendTime[streamID] = now

        receiverMediaFeedbackSequence &+= 1
        let recoveryStatus = sessionStore.sessionByStreamID(streamID)?.clientRecoveryStatus ?? .idle
        let recoveryState = MirageMediaFeedbackRecoveryState(recoveryStatus)
        let transportLoss = receiverTransportLossFeedback(
            for: streamID,
            metrics: metrics,
            recoveryState: recoveryState
        )
        let feedback = Self.makeReceiverMediaFeedback(
            streamID: streamID,
            sequence: receiverMediaFeedbackSequence,
            sentAtUptime: now,
            targetFPS: max(1, metricsStore.snapshot(for: streamID)?.hostTargetFrameRate ?? 60),
            recoveryState: recoveryState,
            transportLostFrameCount: transportLoss.lostFrameCount,
            transportDiscardedPacketCount: transportLoss.discardedPacketCount,
            metrics: metrics
        )
        queueControlMessageBestEffort(.receiverMediaFeedback, content: feedback)
    }

    nonisolated static func makeReceiverMediaFeedback(
        streamID: StreamID,
        sequence: UInt64,
        sentAtUptime: Double,
        targetFPS: Int,
        recoveryState: MirageMediaFeedbackRecoveryState,
        transportLostFrameCount: UInt64 = 0,
        transportDiscardedPacketCount: UInt64 = 0,
        metrics: StreamController.ClientFrameMetrics
    ) -> ReceiverMediaFeedbackMessage {
        ReceiverMediaFeedbackMessage(
            streamID: streamID,
            sequence: sequence,
            sentAtUptime: sentAtUptime,
            targetFPS: targetFPS,
            ackRanges: [],
            lostFrameCount: transportLostFrameCount,
            discardedPacketCount: transportDiscardedPacketCount,
            jitterP95Ms: metrics.receivedFrameIntervalP95Ms,
            jitterP99Ms: metrics.receivedFrameIntervalP99Ms,
            queueEstimateFrames: metrics.pendingFrameCount,
            reassemblyBacklogFrames: metrics.reassemblerPendingFrameCount,
            reassemblyBacklogKeyframes: metrics.reassemblerPendingKeyframeCount,
            reassemblyBacklogBytes: metrics.reassemblerPendingBytes,
            decodeBacklogFrames: 0,
            presentationBacklogFrames: metrics.pendingFrameCount,
            decodedFPS: metrics.decodedFPS,
            receivedFPS: metrics.receivedFPS,
            rendererAcceptedFPS: metrics.layerAcceptedFPS,
            rendererPresentedFPS: metrics.presentedFPS,
            recoveryState: recoveryState
        )
    }

    func clearReceiverMediaFeedbackState(for streamID: StreamID) {
        receiverMediaFeedbackLastSendTime.removeValue(forKey: streamID)
        receiverMediaFeedbackLastIncompleteFrameTimeouts.removeValue(forKey: streamID)
        receiverMediaFeedbackLastMissingFragmentTimeouts.removeValue(forKey: streamID)
    }

    private func receiverTransportLossFeedback(
        for streamID: StreamID,
        metrics: StreamController.ClientFrameMetrics,
        recoveryState: MirageMediaFeedbackRecoveryState
    ) -> ReceiverTransportLossFeedback {
        let currentIncompleteTimeouts = metrics.reassemblerIncompleteFrameTimeouts
        let currentMissingFragments = metrics.reassemblerMissingFragmentTimeouts
        let previousIncompleteTimeouts = receiverMediaFeedbackLastIncompleteFrameTimeouts[streamID] ??
            currentIncompleteTimeouts
        let previousMissingFragments = receiverMediaFeedbackLastMissingFragmentTimeouts[streamID] ??
            currentMissingFragments

        receiverMediaFeedbackLastIncompleteFrameTimeouts[streamID] = currentIncompleteTimeouts
        receiverMediaFeedbackLastMissingFragmentTimeouts[streamID] = currentMissingFragments

        let contaminatedByRecovery = recoveryState != .idle || metrics.reassemblerPendingKeyframeCount > 0
        guard !contaminatedByRecovery else {
            return ReceiverTransportLossFeedback(lostFrameCount: 0, discardedPacketCount: 0)
        }

        let incompleteDelta = currentIncompleteTimeouts >= previousIncompleteTimeouts
            ? currentIncompleteTimeouts - previousIncompleteTimeouts
            : 0
        let missingFragmentDelta = currentMissingFragments >= previousMissingFragments
            ? currentMissingFragments - previousMissingFragments
            : 0
        return ReceiverTransportLossFeedback(
            lostFrameCount: incompleteDelta,
            discardedPacketCount: missingFragmentDelta
        )
    }
}

private struct ReceiverTransportLossFeedback {
    let lostFrameCount: UInt64
    let discardedPacketCount: UInt64
}

private extension MirageMediaFeedbackRecoveryState {
    init(_ status: MirageStreamClientRecoveryStatus) {
        self = switch status {
        case .idle:
            .idle
        case .startup:
            .startup
        case .tierPromotionProbe:
            .tierPromotionProbe
        case .keyframeRecovery:
            .keyframeRecovery
        case .hardRecovery:
            .hardRecovery
        case .postResizeAwaitingFirstFrame:
            .postResizeAwaitingFirstFrame
        }
    }
}
