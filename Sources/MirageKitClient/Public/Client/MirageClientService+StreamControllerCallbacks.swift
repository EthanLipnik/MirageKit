//
//  MirageClientService+StreamControllerCallbacks.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  StreamController callback wiring.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreFoundation
import Foundation

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
                    receiverIngressJitterP95Ms: metrics.receiverIngressJitterP95Ms,
                    receiverIngressJitterP99Ms: metrics.receiverIngressJitterP99Ms,
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
                    frameCompletionLatencyP50Ms: metrics.reassemblerFrameCompletionLatencyP50Ms,
                    frameCompletionLatencyP95Ms: metrics.reassemblerFrameCompletionLatencyP95Ms,
                    frameCompletionLatencyMaxMs: metrics.reassemblerFrameCompletionLatencyMaxMs,
                    keyframeCompletionLatencyP50Ms: metrics.reassemblerKeyframeCompletionLatencyP50Ms,
                    keyframeCompletionLatencyP95Ms: metrics.reassemblerKeyframeCompletionLatencyP95Ms,
                    keyframeCompletionLatencyMaxMs: metrics.reassemblerKeyframeCompletionLatencyMaxMs,
                    pFrameCompletionLatencyP50Ms: metrics.reassemblerPFrameCompletionLatencyP50Ms,
                    pFrameCompletionLatencyP95Ms: metrics.reassemblerPFrameCompletionLatencyP95Ms,
                    pFrameCompletionLatencyMaxMs: metrics.reassemblerPFrameCompletionLatencyMaxMs,
                    latePFrameCompletionCount: metrics.reassemblerLatePFrameCompletionCount,
                    reassemblerFECRecoveredFragmentCount: metrics.reassemblerFECRecoveredFragmentCount,
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
                    pendingFrameNotReadyDisplayTickCount: metrics.pendingFrameNotReadyDisplayTickCount,
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
        let recoveryState = MirageWire.MirageMediaFeedbackRecoveryState(recoveryStatus)
        let audioDroppedFrameCount = audioFeedbackDroppedFrameCountByStreamID[streamID] ?? 0
        let audioGateActive = audioVideoGateActiveStreamIDs.contains(streamID)
        let mediaPathProfile = effectiveMediaPathProfileForCurrentPath ?? .unknown
        let feedbackInterval = resolvedReceiverMediaFeedbackInterval(
            targetFPS: targetFPS,
            recoveryState: recoveryState,
            metrics: metrics,
            mediaPathProfile: mediaPathProfile,
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
        let latestPresentedFrameAgeMs: Double? = latestRenderedTelemetry.renderedFrameSubmittedTime > 0
            ? max(0, (now - latestRenderedTelemetry.renderedFrameSubmittedTime) * 1000)
            : latestAcceptedTimeline?.displayPresentationAcceptedTime.map {
                max(0, (now - $0) * 1000)
            }
        let transportLoss = receiverTransportLossFeedback(
            for: streamID,
            metrics: metrics
        )
        let feedback = Self.makeReceiverMediaFeedback(
            streamID: streamID,
            sequence: receiverMediaFeedbackSequence,
            sentAtUptime: now,
            targetFPS: targetFPS,
            recoveryState: recoveryState,
            recoveryCause: MirageWire.MirageMediaFeedbackRecoveryCause(recoveryCause),
            ackRanges: ackRanges,
            pFrameTimingSamples: pFrameTimingSamples,
            transportLostFrameCount: transportLoss.lostFrameCount,
            transportDiscardedPacketCount: transportLoss.discardedPacketCount,
            latestAcceptedFrameNumber: latestAcceptedTimeline?.frameNumber,
            latestPresentedFrameNumber: latestRenderedTelemetry.renderedFrameNumber,
            latestPresentedFrameAgeMs: latestPresentedFrameAgeMs,
            decodeQueueDepth: metrics.decodeBacklogFrames,
            decodeSubmissionLimit: metrics.decodeSubmissionLimit,
            inFlightDecodeSubmissions: metrics.inFlightDecodeSubmissions,
            presentationQueueDepth: metrics.pendingFrameCount,
            audioDroppedFrameCount: audioDroppedFrameCount > 0 ? audioDroppedFrameCount : nil,
            audioGateActive: audioGateActive ? true : nil,
            mediaPathProfile: mediaPathProfile,
            metrics: metrics
        )
        audioFeedbackDroppedFrameCountByStreamID.removeValue(forKey: streamID)
        queueControlMessageBestEffortUnreliable(.receiverMediaFeedback, content: feedback)
    }

    private func resolvedReceiverMediaFeedbackInterval(
        targetFPS: Int,
        recoveryState: MirageWire.MirageMediaFeedbackRecoveryState,
        metrics: StreamController.ClientFrameMetrics,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown,
        hasAudioPressure: Bool = false
    ) -> CFAbsoluteTime {
        let frameBudgetMs = 1_000.0 / Double(max(1, targetFPS))
        let receiverCadencePressure = metrics.receivedFPS > 0 &&
            metrics.receivedFPS < Double(max(1, targetFPS)) * 0.85
        let receiverJitterP95Ms = Self.reportedReceiverJitterMs(
            receivedFrameIntervalMs: metrics.receivedFrameIntervalP95Ms,
            ingressJitterMs: metrics.receiverIngressJitterP95Ms,
            frameBudgetMs: frameBudgetMs,
            mediaPathProfile: mediaPathProfile
        )
        let receiverJitterP99Ms = Self.reportedReceiverJitterMs(
            receivedFrameIntervalMs: metrics.receivedFrameIntervalP99Ms,
            ingressJitterMs: metrics.receiverIngressJitterP99Ms,
            frameBudgetMs: frameBudgetMs,
            mediaPathProfile: mediaPathProfile
        )
        let receiveGapPressure = metrics.receivedWorstGapMs > frameBudgetMs * 3.0 ||
            receiverJitterP95Ms > frameBudgetMs ||
            receiverJitterP99Ms > frameBudgetMs * 1.5
        let pFramePressure = metrics.reassemblerPFrameCompletionLatencyP95Ms > frameBudgetMs * 2.5
        let presentationBacklogFrames = Self.presentationBacklogFrames(targetFPS: targetFPS, metrics: metrics)
        let backlogPressure = metrics.reassemblerPendingFrameCount > 3 ||
            metrics.reassemblerPendingBytes > 1_000_000 ||
            metrics.decodeBacklogFrames > 2 ||
            presentationBacklogFrames > 2
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
        recoveryState: MirageWire.MirageMediaFeedbackRecoveryState,
        recoveryCause: MirageWire.MirageMediaFeedbackRecoveryCause = .none,
        ackRanges: [MirageWire.MediaFeedbackFrameRange] = [],
        pFrameTimingSamples: [MirageWire.ReceiverPFrameTimingSample] = [],
        transportLostFrameCount: UInt64 = 0,
        transportDiscardedPacketCount: UInt64 = 0,
        latestAcceptedFrameNumber: UInt32? = nil,
        latestPresentedFrameNumber: UInt32? = nil,
        latestPresentedFrameAgeMs: Double? = nil,
        decodeQueueDepth: Int? = nil,
        decodeSubmissionLimit: Int? = nil,
        inFlightDecodeSubmissions: Int? = nil,
        presentationQueueDepth: Int? = nil,
        audioDroppedFrameCount: UInt64? = nil,
        audioGateActive: Bool? = nil,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown,
        metrics: StreamController.ClientFrameMetrics
    ) -> MirageWire.ReceiverMediaFeedbackMessage {
        let frameBudgetMs = 1_000.0 / Double(max(1, targetFPS))
        return MirageWire.ReceiverMediaFeedbackMessage(
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
            presentationBacklogFrames: presentationBacklogFrames(targetFPS: targetFPS, metrics: metrics),
            decodedFPS: metrics.decodedFPS,
            receivedFPS: metrics.receivedFPS,
            rendererAcceptedFPS: metrics.layerAcceptedFPS,
            rendererPresentedFPS: metrics.visibleFrameFPS,
            recoveryState: recoveryState,
            recoveryCause: recoveryCause,
            frameCompletionLatencyP50Ms: metrics.reassemblerFrameCompletionLatencyP50Ms,
            frameCompletionLatencyP95Ms: metrics.reassemblerFrameCompletionLatencyP95Ms,
            frameCompletionLatencyMaxMs: metrics.reassemblerFrameCompletionLatencyMaxMs,
            keyframeCompletionLatencyP50Ms: metrics.reassemblerKeyframeCompletionLatencyP50Ms,
            keyframeCompletionLatencyP95Ms: metrics.reassemblerKeyframeCompletionLatencyP95Ms,
            keyframeCompletionLatencyMaxMs: metrics.reassemblerKeyframeCompletionLatencyMaxMs,
            pFrameCompletionLatencyP50Ms: metrics.reassemblerPFrameCompletionLatencyP50Ms,
            pFrameCompletionLatencyP95Ms: metrics.reassemblerPFrameCompletionLatencyP95Ms,
            pFrameCompletionLatencyMaxMs: metrics.reassemblerPFrameCompletionLatencyMaxMs,
            latePFrameCount: metrics.reassemblerLatePFrameCompletionCount,
            receivedWorstGapMs: metrics.receivedWorstGapMs,
            presentationStallCount: metrics.presentationStallCount,
            displayTickNoFrameCount: metrics.displayTickNoFrameCount,
            pendingFrameNotReadyDisplayTickCount: metrics.pendingFrameNotReadyDisplayTickCount,
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
            decodeSubmissionLimit: decodeSubmissionLimit,
            inFlightDecodeSubmissions: inFlightDecodeSubmissions,
            presentationQueueDepth: presentationQueueDepth,
            presentationTargetFrames: presentationTargetFrames(targetFPS: targetFPS, metrics: metrics),
            presentationFillDeficitFrames: presentationFillDeficitFrames(targetFPS: targetFPS, metrics: metrics),
            presentationUnderfillFrames: presentationUnderfillFrames(targetFPS: targetFPS, metrics: metrics),
            receiverJitterP95Ms: reportedReceiverJitterMs(
                receivedFrameIntervalMs: metrics.receivedFrameIntervalP95Ms,
                ingressJitterMs: metrics.receiverIngressJitterP95Ms,
                frameBudgetMs: frameBudgetMs,
                mediaPathProfile: mediaPathProfile
            ),
            receiverJitterP99Ms: reportedReceiverJitterMs(
                receivedFrameIntervalMs: metrics.receivedFrameIntervalP99Ms,
                ingressJitterMs: metrics.receiverIngressJitterP99Ms,
                frameBudgetMs: frameBudgetMs,
                mediaPathProfile: mediaPathProfile
            ),
            audioDroppedFrameCount: audioDroppedFrameCount,
            audioGateActive: audioGateActive
        )
    }

    nonisolated private static func presentationTargetFrames(
        targetFPS: Int,
        metrics: StreamController.ClientFrameMetrics
    ) -> Int {
        guard metrics.smoothestTargetDelayMs > 0 else { return 0 }
        let frameBudgetMs = 1_000.0 / Double(max(1, targetFPS))
        return max(1, Int((metrics.smoothestTargetDelayMs / frameBudgetMs).rounded(.up)))
    }

    nonisolated private static func presentationBacklogFrames(
        targetFPS: Int,
        metrics: StreamController.ClientFrameMetrics
    ) -> Int {
        max(0, metrics.pendingFrameCount - presentationTargetFrames(targetFPS: targetFPS, metrics: metrics))
    }

    nonisolated private static func presentationFillDeficitFrames(
        targetFPS: Int,
        metrics: StreamController.ClientFrameMetrics
    ) -> Int {
        max(0, presentationTargetFrames(targetFPS: targetFPS, metrics: metrics) - metrics.pendingFrameCount)
    }

    nonisolated private static func presentationUnderfillFrames(
        targetFPS: Int,
        metrics: StreamController.ClientFrameMetrics
    ) -> Int {
        guard metrics.presentationStallCount > 0 ||
            metrics.displayTickNoFrameCount > 0 ||
            metrics.pendingFrameNotReadyDisplayTickCount > 0 else {
            return 0
        }
        return max(0, presentationTargetFrames(targetFPS: targetFPS, metrics: metrics) - metrics.pendingFrameCount)
    }

    nonisolated private static func receiverJitterMs(
        receivedFrameIntervalMs: Double,
        frameBudgetMs: Double
    ) -> Double {
        max(0, receivedFrameIntervalMs - frameBudgetMs)
    }

    nonisolated private static func reportedReceiverJitterMs(
        receivedFrameIntervalMs: Double,
        ingressJitterMs: Double,
        frameBudgetMs: Double,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile
    ) -> Double {
        if mediaPathProfile.usesAwdlRadioPolicy {
            return max(0, ingressJitterMs)
        }
        return max(
            receiverJitterMs(
                receivedFrameIntervalMs: receivedFrameIntervalMs,
                frameBudgetMs: frameBudgetMs
            ),
            max(0, ingressJitterMs)
        )
    }

    nonisolated static func receiverReliabilityCauses(
        recoveryState: MirageWire.MirageMediaFeedbackRecoveryState,
        metrics: StreamController.ClientFrameMetrics
    ) -> [MirageWire.ReceiverMediaFeedbackReliabilityCause] {
        var causes: [MirageWire.ReceiverMediaFeedbackReliabilityCause] = []
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

        var seen = Set<MirageWire.ReceiverMediaFeedbackReliabilityCause>()
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
        metrics: StreamController.ClientFrameMetrics
    ) -> ReceiverTransportLossFeedback {
        let currentIncompleteTimeouts = metrics.reassemblerIncompleteFrameTimeouts
        let currentForwardGapTimeouts = metrics.reassemblerForwardGapTimeouts
        let currentMissingFragments = metrics.reassemblerMissingFragmentTimeouts
        let previousIncompleteTimeouts = receiverMediaFeedbackLastIncompleteFrameTimeouts[streamID] ?? 0
        let previousForwardGapTimeouts = receiverMediaFeedbackLastForwardGapTimeouts[streamID] ?? 0
        let previousMissingFragments = receiverMediaFeedbackLastMissingFragmentTimeouts[streamID] ?? 0

        receiverMediaFeedbackLastIncompleteFrameTimeouts[streamID] = currentIncompleteTimeouts
        receiverMediaFeedbackLastForwardGapTimeouts[streamID] = currentForwardGapTimeouts
        receiverMediaFeedbackLastMissingFragmentTimeouts[streamID] = currentMissingFragments

        return Self.receiverTransportLossFeedback(
            currentIncompleteFrameTimeouts: currentIncompleteTimeouts,
            previousIncompleteFrameTimeouts: previousIncompleteTimeouts,
            currentForwardGapTimeouts: currentForwardGapTimeouts,
            previousForwardGapTimeouts: previousForwardGapTimeouts,
            currentMissingFragmentTimeouts: currentMissingFragments,
            previousMissingFragmentTimeouts: previousMissingFragments
        )
    }

    nonisolated static func receiverTransportLossFeedback(
        currentIncompleteFrameTimeouts: UInt64,
        previousIncompleteFrameTimeouts: UInt64,
        currentForwardGapTimeouts: UInt64,
        previousForwardGapTimeouts: UInt64,
        currentMissingFragmentTimeouts: UInt64,
        previousMissingFragmentTimeouts: UInt64
    ) -> ReceiverTransportLossFeedback {
        let incompleteDelta = currentIncompleteFrameTimeouts >= previousIncompleteFrameTimeouts
            ? currentIncompleteFrameTimeouts - previousIncompleteFrameTimeouts
            : 0
        let forwardGapDelta = currentForwardGapTimeouts >= previousForwardGapTimeouts
            ? currentForwardGapTimeouts - previousForwardGapTimeouts
            : 0
        let missingFragmentDelta = currentMissingFragmentTimeouts >= previousMissingFragmentTimeouts
            ? currentMissingFragmentTimeouts - previousMissingFragmentTimeouts
            : 0
        return ReceiverTransportLossFeedback(
            lostFrameCount: incompleteDelta + forwardGapDelta,
            discardedPacketCount: missingFragmentDelta
        )
    }
}

struct ReceiverTransportLossFeedback: Equatable {
    let lostFrameCount: UInt64
    let discardedPacketCount: UInt64
}

private extension MirageWire.MirageMediaFeedbackRecoveryState {
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

private extension MirageWire.MirageMediaFeedbackRecoveryCause {
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
