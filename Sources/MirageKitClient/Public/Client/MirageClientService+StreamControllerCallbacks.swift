//
//  MirageClientService+StreamControllerCallbacks.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  StreamController callback wiring.
//

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
                self?.sendKeyframeRequest(for: streamID)
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
                    displayTickFPS: metrics.displayTickFPS,
                    submitAttemptFPS: metrics.submitAttemptFPS,
                    layerAcceptedFPS: metrics.layerAcceptedFPS,
                    presentedFPS: metrics.presentedFPS,
                    submittedFPS: metrics.submittedFPS,
                    uniqueSubmittedFPS: metrics.uniqueSubmittedFPS,
                    pendingFrameCount: metrics.pendingFrameCount,
                    pendingFrameAgeMs: metrics.pendingFrameAgeMs,
                    overwrittenPendingFrames: metrics.overwrittenPendingFrames,
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
                logAwdlExperimentTelemetryIfNeeded()
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
}
