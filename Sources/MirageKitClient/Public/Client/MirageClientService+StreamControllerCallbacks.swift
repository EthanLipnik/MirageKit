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
        await controller.setCallbacks(
            onKeyframeNeeded: { [weak self] in
                self?.sendKeyframeRequest(for: streamID) ?? false
            },
            onResizeStateChanged: nil,
            onFrameDecoded: { [weak self] metrics in
                guard let self else { return }
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
                    reassemblerIncompleteFrameNoProgressTimeouts: metrics.reassemblerIncompleteFrameNoProgressTimeouts,
                    reassemblerIncompleteFrameLifetimeTimeouts: metrics.reassemblerIncompleteFrameLifetimeTimeouts,
                    reassemblerMissingFragmentTimeouts: metrics.reassemblerMissingFragmentTimeouts,
                    reassemblerForwardGapTimeouts: metrics.reassemblerForwardGapTimeouts,
                    pFrameCompletionLatencyP50Ms: metrics.reassemblerPFrameCompletionLatencyP50Ms,
                    pFrameCompletionLatencyP95Ms: metrics.reassemblerPFrameCompletionLatencyP95Ms,
                    pFrameCompletionLatencyMaxMs: metrics.reassemblerPFrameCompletionLatencyMaxMs,
                    latePFrameCompletionCount: metrics.reassemblerLatePFrameCompletionCount,
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
                    smoothestDisplayDebtDrops: metrics.smoothestDisplayDebtDrops,
                    smoothestFifoResetCount: metrics.smoothestFifoResetCount,
                    smoothestDepthDrops: metrics.smoothestDepthDrops,
                    smoothestAgeDrops: metrics.smoothestAgeDrops,
                    smoothestDropsUnder100ms: metrics.smoothestDropsUnder100ms,
                    smoothestDroppedFrameAgeMaxMs: metrics.smoothestDroppedFrameAgeMaxMs,
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
            videoIngressMetricsProvider: { [videoIngressTelemetryStore] streamID in
                videoIngressTelemetryStore.snapshot(for: streamID)
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
            recoveryState: recoveryState,
            pFrameCompletionLatencyP50Ms: metrics.reassemblerPFrameCompletionLatencyP50Ms,
            pFrameCompletionLatencyP95Ms: metrics.reassemblerPFrameCompletionLatencyP95Ms,
            pFrameCompletionLatencyMaxMs: metrics.reassemblerPFrameCompletionLatencyMaxMs,
            latePFrameCount: metrics.reassemblerLatePFrameCompletionCount,
            reliabilityCauses: receiverReliabilityCauses(
                recoveryState: recoveryState,
                metrics: metrics
            )
        )
    }

    nonisolated static func receiverReliabilityCauses(
        recoveryState: MirageMediaFeedbackRecoveryState,
        metrics: StreamController.ClientFrameMetrics
    ) -> [ReceiverMediaFeedbackReliabilityCause] {
        var causes: [ReceiverMediaFeedbackReliabilityCause] = []
        if metrics.reassemblerIncompleteFrameNoProgressTimeouts > 0 {
            causes.append(.noProgressTimeout)
        }
        if metrics.reassemblerIncompleteFrameLifetimeTimeouts > 0 {
            causes.append(.absoluteLifetimeTimeout)
        }
        if metrics.reassemblerForwardGapTimeouts > 0 {
            causes.append(.forwardGapStall)
        }
        if metrics.reassemblerBudgetEvictions > 0 {
            causes.append(.memoryPressure)
        }

        switch recoveryState {
        case .keyframeRecovery:
            causes.append(.keyframeStarvation)
        case .hardRecovery,
             .postResizeAwaitingFirstFrame,
             .tierPromotionProbe:
            causes.append(.presentationLifecycle)
        case .idle,
             .startup:
            break
        }

        var seen = Set<ReceiverMediaFeedbackReliabilityCause>()
        return causes.filter { seen.insert($0).inserted }
    }

    func clearReceiverMediaFeedbackState(for streamID: StreamID) {
        receiverMediaFeedbackLastSendTime.removeValue(forKey: streamID)
        receiverMediaFeedbackLastIncompleteFrameTimeouts.removeValue(forKey: streamID)
        receiverMediaFeedbackLastForwardGapTimeouts.removeValue(forKey: streamID)
        receiverMediaFeedbackLastMissingFragmentTimeouts.removeValue(forKey: streamID)
    }

    private func receiverTransportLossFeedback(
        for streamID: StreamID,
        metrics: StreamController.ClientFrameMetrics,
        recoveryState: MirageMediaFeedbackRecoveryState
    ) -> ReceiverTransportLossFeedback {
        let currentIncompleteTimeouts = metrics.reassemblerIncompleteFrameTimeouts
        let currentForwardGapTimeouts = metrics.reassemblerForwardGapTimeouts
        let currentMissingFragments = metrics.reassemblerMissingFragmentTimeouts
        let previousIncompleteTimeouts = receiverMediaFeedbackLastIncompleteFrameTimeouts[streamID] ??
            currentIncompleteTimeouts
        let previousForwardGapTimeouts = receiverMediaFeedbackLastForwardGapTimeouts[streamID] ??
            currentForwardGapTimeouts
        let previousMissingFragments = receiverMediaFeedbackLastMissingFragmentTimeouts[streamID] ??
            currentMissingFragments

        receiverMediaFeedbackLastIncompleteFrameTimeouts[streamID] = currentIncompleteTimeouts
        receiverMediaFeedbackLastForwardGapTimeouts[streamID] = currentForwardGapTimeouts
        receiverMediaFeedbackLastMissingFragmentTimeouts[streamID] = currentMissingFragments

        let contaminatedByRecovery = recoveryState != .idle || metrics.reassemblerPendingKeyframeCount > 0
        guard !contaminatedByRecovery else {
            return ReceiverTransportLossFeedback(lostFrameCount: 0, discardedPacketCount: 0)
        }

        let incompleteDelta = currentIncompleteTimeouts >= previousIncompleteTimeouts
            ? currentIncompleteTimeouts - previousIncompleteTimeouts
            : 0
        let forwardGapDelta = currentForwardGapTimeouts >= previousForwardGapTimeouts
            ? currentForwardGapTimeouts - previousForwardGapTimeouts
            : 0
        let missingFragmentDelta = currentMissingFragments >= previousMissingFragments
            ? currentMissingFragments - previousMissingFragments
            : 0
        return ReceiverTransportLossFeedback(
            lostFrameCount: incompleteDelta + forwardGapDelta,
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
