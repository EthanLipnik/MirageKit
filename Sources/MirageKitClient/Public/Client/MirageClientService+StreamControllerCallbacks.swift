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
            onKeyframeNeeded: { [weak self, weak controller] in
                guard let self,
                      self.isActiveStreamController(controller, streamID: streamID) else {
                    return false
                }
                return sendKeyframeRequest(for: streamID)
            },
            onResizeStateChanged: nil,
            onFrameDecoded: { [weak self, weak controller] metrics in
                guard let self,
                      let controller,
                      self.isActiveStreamController(controller, streamID: streamID) else {
                    return
                }
                metricsStore.updateClientMetrics(
                    streamID: streamID,
                    decodedFPS: metrics.decodedFPS,
                    receivedFPS: metrics.receivedFPS,
                    receivedWorstGapMs: metrics.receivedWorstGapMs,
                    receivedFrameIntervalP95Ms: metrics.receivedFrameIntervalP95Ms,
                    receivedFrameIntervalP99Ms: metrics.receivedFrameIntervalP99Ms,
                    droppedFrames: metrics.droppedFrames,
                    decodeBacklogFrames: metrics.decodeBacklogFrames,
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
                    presentedFPS: metrics.visibleFrameFPS,
                    submittedFPS: metrics.submittedFPS,
                    uniqueSubmittedFPS: metrics.uniqueSubmittedFPS,
                    pendingFrameCount: metrics.pendingFrameCount,
                    pendingFrameAgeMs: metrics.pendingFrameAgeMs,
                    smoothestDisplayDebtMs: metrics.smoothestDisplayDebtMs,
                    smoothestDisplayDebtCapMs: metrics.smoothestDisplayDebtCapMs,
                    smoothestTargetDelayMs: metrics.smoothestTargetDelayMs,
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
                    displayTickNoFrameCount: metrics.displayTickNoFrameCount,
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
                sendReceiverMediaFeedback(streamID: streamID, controller: controller, metrics: metrics)
                logAwdlRadioTelemetryIfNeeded(streamID: streamID, metrics: metrics)
            },
            videoIngressMetricsProvider: { [videoIngressTelemetryStore] streamID in
                videoIngressTelemetryStore.snapshot(for: streamID)
            },
            onFirstFrameDecoded: { [weak self, weak controller] in
                guard let self,
                      self.isActiveStreamController(controller, streamID: streamID) else {
                    return
                }
                sessionStore.markFirstFrameDecoded(for: streamID)
                MirageLogger.signpostEvent(.client, "Startup.FirstFrameDecoded", "stream=\(streamID)")
            },
            onFirstFramePresented: { [weak self, weak controller] in
                guard let self,
                      self.isActiveStreamController(controller, streamID: streamID) else {
                    return
                }
                handleStreamFirstFramePresented(streamID: streamID)
                clearStartupAttempt(for: streamID)
                MirageLogger.signpostEvent(.client, "Startup.FirstFramePresented", "stream=\(streamID)")
            },
            onStallEvent: { [weak self, weak controller] event in
                guard let self,
                      self.isActiveStreamController(controller, streamID: streamID) else {
                    return
                }
                stallEvents &+= 1
                handleRuntimeWorkloadSafetyStallEvent(streamID: streamID, event: event)
                logAwdlRadioTelemetryIfNeeded()
            },
            onRecoveryStatusChanged: nil,
            onRecoveryStateChanged: { [weak self, weak controller] status, cause in
                guard let self,
                      self.isActiveStreamController(controller, streamID: streamID) else {
                    return
                }
                sessionStore.setClientRecoveryStatus(for: streamID, status: status, cause: cause)
                if status == .idle {
                    handleDesktopPresentationReady(streamID: streamID)
                }
            },
            onTerminalStartupFailure: { [weak self, weak controller] failure in
                guard let self,
                      self.isActiveStreamController(controller, streamID: streamID) else {
                    return
                }
                Task {
                    await self.handleTerminalStartupFailure(failure, for: streamID)
                }
            }
        )
    }

    private func isActiveStreamController(_ controller: StreamController?, streamID: StreamID) -> Bool {
        guard let controller else { return false }
        return controllersByStream[streamID] === controller
    }

    private func sendReceiverMediaFeedback(
        streamID: StreamID,
        controller: StreamController,
        metrics: StreamController.ClientFrameMetrics
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let targetFPS = max(1, metricsStore.snapshot(for: streamID)?.hostTargetFrameRate ?? 60)
        let session = sessionStore.sessionByStreamID(streamID)
        let recoveryStatus = session?.clientRecoveryStatus ?? .idle
        let recoveryCause = session?.clientRecoveryCause ?? .none
        let recoveryState = MirageMediaFeedbackRecoveryState(recoveryStatus)
        let audioDroppedFrameCount = audioFeedbackDroppedFrameCountByStreamID[streamID] ?? 0
        let audioGateActive = audioVideoGateActiveStreamIDs.contains(streamID)
        let feedbackInterval = resolvedReceiverMediaFeedbackInterval(
            targetFPS: targetFPS,
            recoveryState: recoveryState,
            metrics: metrics,
            hasAudioPressure: audioDroppedFrameCount > 0 || audioGateActive
        )
        if let lastSendTime = receiverMediaFeedbackLastSendTime[streamID],
           now - lastSendTime < feedbackInterval {
            return
        }
        receiverMediaFeedbackLastSendTime[streamID] = now

        receiverMediaFeedbackSequence &+= 1
        let ackRanges = controller.reassembler.consumeCompletedFrameAckRanges()
        let pFrameTimingSamples = controller.reassembler.consumePFrameTimingSamples()
        let latestAcceptedTimeline = MirageRenderStreamStore.shared.latestAcceptedFrameTimeline(for: streamID)
        let latestRenderedTelemetry = MirageRenderStreamStore.shared.renderedFrameTelemetry(for: streamID)
        let latestAcceptedFrameAgeMs = latestAcceptedTimeline?.displayPresentationAcceptedTime.map {
            max(0, (now - $0) * 1000)
        }
        let transportLoss = receiverTransportLossFeedback(
            for: streamID,
            metrics: metrics,
            recoveryState: recoveryState
        )
        let feedback = Self.makeReceiverMediaFeedback(
            streamID: streamID,
            sequence: receiverMediaFeedbackSequence,
            sentAtUptime: now,
            targetFPS: targetFPS,
            recoveryState: recoveryState,
            recoveryCause: MirageMediaFeedbackRecoveryCause(recoveryCause),
            ackRanges: ackRanges,
            pFrameTimingSamples: pFrameTimingSamples,
            transportLostFrameCount: transportLoss.lostFrameCount,
            transportDiscardedPacketCount: transportLoss.discardedPacketCount,
            latestAcceptedFrameNumber: latestAcceptedTimeline?.frameNumber,
            latestPresentedFrameNumber: latestRenderedTelemetry.renderedFrameNumber,
            latestPresentedFrameAgeMs: latestAcceptedFrameAgeMs,
            decodeQueueDepth: metrics.decodeBacklogFrames,
            presentationQueueDepth: metrics.pendingFrameCount,
            audioDroppedFrameCount: audioDroppedFrameCount > 0 ? audioDroppedFrameCount : nil,
            audioGateActive: audioGateActive ? true : nil,
            metrics: metrics
        )
        audioFeedbackDroppedFrameCountByStreamID.removeValue(forKey: streamID)
        queueControlMessageBestEffortUnreliable(.receiverMediaFeedback, content: feedback)
    }

    private func resolvedReceiverMediaFeedbackInterval(
        targetFPS: Int,
        recoveryState: MirageMediaFeedbackRecoveryState,
        metrics: StreamController.ClientFrameMetrics,
        hasAudioPressure: Bool = false
    ) -> CFAbsoluteTime {
        let frameBudgetMs = 1_000.0 / Double(max(1, targetFPS))
        let receiverCadencePressure = metrics.receivedFPS > 0 &&
            metrics.receivedFPS < Double(max(1, targetFPS)) * 0.85
        let receiveGapPressure = metrics.receivedWorstGapMs > frameBudgetMs * 3.0 ||
            metrics.receivedFrameIntervalP95Ms > frameBudgetMs * 2.0 ||
            metrics.receivedFrameIntervalP99Ms > frameBudgetMs * 2.5
        let pFramePressure = metrics.reassemblerPFrameCompletionLatencyP95Ms > frameBudgetMs * 2.5
        let backlogPressure = metrics.reassemblerPendingFrameCount > 3 ||
            metrics.reassemblerPendingBytes > 1_000_000 ||
            metrics.decodeBacklogFrames > 2 ||
            metrics.pendingFrameCount > 2
        let visibleStress = metrics.presentationStallCount > 0 ||
            metrics.displayTickNoFrameCount > 0 ||
            (metrics.layerAcceptedFPS > 0 && metrics.visibleFrameFPS < metrics.layerAcceptedFPS * 0.85)
        let stressed = recoveryState != .idle ||
            receiverCadencePressure ||
            receiveGapPressure ||
            pFramePressure ||
            backlogPressure ||
            visibleStress ||
            hasAudioPressure
        return stressed ? 0.10 : receiverMediaFeedbackInterval
    }

    nonisolated static func makeReceiverMediaFeedback(
        streamID: StreamID,
        sequence: UInt64,
        sentAtUptime: Double,
        targetFPS: Int,
        recoveryState: MirageMediaFeedbackRecoveryState,
        recoveryCause: MirageMediaFeedbackRecoveryCause = .none,
        ackRanges: [MediaFeedbackFrameRange] = [],
        pFrameTimingSamples: [ReceiverPFrameTimingSample] = [],
        transportLostFrameCount: UInt64 = 0,
        transportDiscardedPacketCount: UInt64 = 0,
        latestAcceptedFrameNumber: UInt32? = nil,
        latestPresentedFrameNumber: UInt32? = nil,
        latestPresentedFrameAgeMs: Double? = nil,
        decodeQueueDepth: Int? = nil,
        presentationQueueDepth: Int? = nil,
        audioDroppedFrameCount: UInt64? = nil,
        audioGateActive: Bool? = nil,
        metrics: StreamController.ClientFrameMetrics
    ) -> ReceiverMediaFeedbackMessage {
        ReceiverMediaFeedbackMessage(
            streamID: streamID,
            sequence: sequence,
            sentAtUptime: sentAtUptime,
            targetFPS: targetFPS,
            ackRanges: ackRanges,
            pFrameTimingSamples: pFrameTimingSamples,
            lostFrameCount: transportLostFrameCount,
            discardedPacketCount: transportDiscardedPacketCount,
            jitterP95Ms: metrics.receivedFrameIntervalP95Ms,
            jitterP99Ms: metrics.receivedFrameIntervalP99Ms,
            queueEstimateFrames: metrics.pendingFrameCount,
            reassemblyBacklogFrames: metrics.reassemblerPendingFrameCount,
            reassemblyBacklogKeyframes: metrics.reassemblerPendingKeyframeCount,
            reassemblyBacklogBytes: metrics.reassemblerPendingBytes,
            decodeBacklogFrames: metrics.decodeBacklogFrames,
            presentationBacklogFrames: metrics.pendingFrameCount,
            decodedFPS: metrics.decodedFPS,
            receivedFPS: metrics.receivedFPS,
            rendererAcceptedFPS: metrics.layerAcceptedFPS,
            rendererPresentedFPS: metrics.visibleFrameFPS,
            recoveryState: recoveryState,
            recoveryCause: recoveryCause,
            pFrameCompletionLatencyP50Ms: metrics.reassemblerPFrameCompletionLatencyP50Ms,
            pFrameCompletionLatencyP95Ms: metrics.reassemblerPFrameCompletionLatencyP95Ms,
            pFrameCompletionLatencyMaxMs: metrics.reassemblerPFrameCompletionLatencyMaxMs,
            latePFrameCount: metrics.reassemblerLatePFrameCompletionCount,
            receivedWorstGapMs: metrics.receivedWorstGapMs,
            presentationStallCount: metrics.presentationStallCount,
            displayTickNoFrameCount: metrics.displayTickNoFrameCount,
            worstPresentationGapMs: metrics.worstPresentationGapMs,
            playoutDelayFrames: metrics.playoutDelayFrames,
            playoutDelayTargetMs: metrics.smoothestTargetDelayMs,
            reassemblerIncompleteFrameTimeouts: metrics.reassemblerIncompleteFrameTimeouts,
            reassemblerMissingFragmentTimeouts: metrics.reassemblerMissingFragmentTimeouts,
            reassemblerForwardGapTimeouts: metrics.reassemblerForwardGapTimeouts,
            fecRecoveredFragmentCount: metrics.reassemblerFECRecoveredFragmentCount,
            reliabilityCauses: receiverReliabilityCauses(
                recoveryState: recoveryState,
                metrics: metrics
            ),
            latestAcceptedFrameNumber: latestAcceptedFrameNumber,
            latestPresentedFrameNumber: latestPresentedFrameNumber,
            latestPresentedFrameAgeMs: latestPresentedFrameAgeMs,
            decodeQueueDepth: decodeQueueDepth,
            presentationQueueDepth: presentationQueueDepth,
            audioDroppedFrameCount: audioDroppedFrameCount,
            audioGateActive: audioGateActive
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

private extension MirageMediaFeedbackRecoveryCause {
    init(_ cause: MirageStreamClientRecoveryCause) {
        self = switch cause {
        case .none:
            .none
        case .decodeError:
            .decodeError
        case .frameLoss:
            .frameLoss
        case .freezeTimeout:
            .freezeTimeout
        case .memoryBudget:
            .memoryBudget
        case .startupTimeout:
            .startupTimeout
        case .manual:
            .manual
        }
    }
}
