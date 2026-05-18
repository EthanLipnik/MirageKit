//
//  MirageClientService+StreamRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import CoreGraphics
import Foundation
import MirageKit

/// Source of a client-side stream recovery request.
enum MirageClientStreamRecoveryTrigger {
    /// User-initiated recovery that asks for a keyframe without gating on presentation.
    case manual

    /// App foregrounding recovery that waits for a newly presented frame before clearing.
    case applicationActivation

    /// Stable label used in diagnostics and recovery logs.
    var logLabel: String {
        switch self {
        case .manual:
            "manual"
        case .applicationActivation:
            "application-activation"
        }
    }

    /// Whether recovery should remain active until the renderer presents a newer frame.
    var awaitFirstPresentedFrame: Bool {
        switch self {
        case .manual:
            false
        case .applicationActivation:
            true
        }
    }

    /// Whether recovery should immediately flush pending render frames.
    var clearsExistingFramesImmediately: Bool {
        switch self {
        case .manual:
            true
        case .applicationActivation:
            false
        }
    }

    /// Whether recovery should immediately reset the platform presenter.
    var requestsPresentationRecoveryImmediately: Bool {
        switch self {
        case .manual:
            true
        case .applicationActivation:
            false
        }
    }

    /// Session-store wait reason used when `awaitFirstPresentedFrame` is active.
    var firstPresentedFrameWaitReason: String? {
        switch self {
        case .manual:
            nil
        case .applicationActivation:
            "application-activation-recovery"
        }
    }
}

@MainActor
extension MirageClientService {
    /// Requests presentation recovery for an active stream and asks the host for a keyframe.
    public func requestStreamRecovery(for streamID: StreamID) {
        requestStreamRecovery(for: streamID, trigger: .manual)
    }

    func replayPendingApplicationActivationRecoveryIfNeeded(for streamID: StreamID) {
        guard pendingApplicationActivationRecoveryStreamIDs.remove(streamID) != nil else { return }
        MirageLogger.client(
            "Replaying deferred application activation recovery for stream \(streamID)"
        )
        requestStreamRecovery(for: streamID, trigger: .applicationActivation)
    }

    /// Captures the client-side health signals used to decide whether a foreground stream is flowing.
    ///
    /// The snapshot is local to the client process; it does not query the host or wait for network I/O.
    public func foregroundStreamHealthSnapshot(
        for streamID: StreamID
    ) async -> ForegroundStreamHealthSnapshot {
        let controller = controllersByStream[streamID]
        let reassembler = controller?.reassembler
        let submissionSnapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)

        return ForegroundStreamHealthSnapshot(
            streamID: streamID,
            hasController: controller != nil,
            hasVideoMediaStream: activeMediaStreams["video/\(streamID)"] != nil,
            latestPacketTime: reassembler?.latestPacketReceivedTime ?? 0,
            submittedSequence: submissionSnapshot.sequence,
            isAwaitingKeyframe: reassembler?.isAwaitingKeyframe ?? true
        )
    }

    func cancelRecoveryKeyframeRetry(for streamID: StreamID) {
        guard let retry = recoveryKeyframeRetryTasks.removeValue(forKey: streamID) else { return }
        retry.task.cancel()
    }

    func cancelRecoveryKeyframeRetries() {
        let retries = recoveryKeyframeRetryTasks.values
        recoveryKeyframeRetryTasks.removeAll()
        for retry in retries {
            retry.task.cancel()
        }
    }

    /// Sends a live encoder settings update for an active stream.
    ///
    /// `streamScale` and `targetFrameRate` are clamped to the service's current runtime limits before
    /// being sent. Passing no non-`nil` settings is treated as a no-op.
    public func sendStreamEncoderSettingsChange(
        streamID: StreamID,
        colorDepth: MirageStreamColorDepth? = nil,
        bitrate: Int? = nil,
        streamScale: CGFloat? = nil,
        targetFrameRate: Int? = nil
    )
    async throws {
        guard case .connected = connectionState else {
            throw MirageError.protocolError("Not connected")
        }
        guard colorDepth != nil || bitrate != nil || streamScale != nil || targetFrameRate != nil else {
            return
        }

        let clampedScale = streamScale.map(MirageStreamGeometry.clampStreamScale)
        let clampedFrameRate = targetFrameRate.map {
            Self.runtimeWorkloadSafetyCappedFrameRate(
                $0,
                cap: runtimeWorkloadSafetyFrameRateCap(for: streamID)
            )
        }
        let request = StreamEncoderSettingsChangeMessage(
            streamID: streamID,
            colorDepth: colorDepth,
            bitrate: bitrate,
            streamScale: clampedScale,
            targetFrameRate: clampedFrameRate
        )
        if let bitrate {
            MirageLogger.client(
                "Requesting encoder bitrate update for stream \(streamID): \(mirageFormattedMegabitRate(bitrate))"
            )
        }
        if let clampedFrameRate {
            MirageLogger.client(
                "Requesting encoder frame-rate update for stream \(streamID): \(clampedFrameRate)fps"
            )
        }
        try await sendControlMessage(.streamEncoderSettingsChange, content: request)
        if let clampedScale {
            resolutionScale = clampedScale
        }
        if let clampedFrameRate {
            refreshRateOverridesByStream[streamID] = clampedFrameRate
            await applyStreamCadenceTarget(
                clampedFrameRate,
                for: streamID,
                reason: "encoder settings change"
            )
        }
    }

    func configureDecoderColorDepthBaseline(
        for streamID: StreamID,
        colorDepth: MirageStreamColorDepth?
    ) {
        if let colorDepth {
            decoderCompatibilityCurrentColorDepthByStream[streamID] = colorDepth
            decoderCompatibilityBaselineColorDepthByStream[streamID] = colorDepth
        } else {
            decoderCompatibilityCurrentColorDepthByStream.removeValue(forKey: streamID)
            decoderCompatibilityBaselineColorDepthByStream.removeValue(forKey: streamID)
        }
    }

    func clearDecoderColorDepthState(for streamID: StreamID) {
        decoderCompatibilityCurrentColorDepthByStream.removeValue(forKey: streamID)
        decoderCompatibilityBaselineColorDepthByStream.removeValue(forKey: streamID)
    }
}

extension MirageClientService {
    func requestStreamRecovery(
        for streamID: StreamID,
        trigger: MirageClientStreamRecoveryTrigger
    ) {
        guard case .connected = connectionState else {
            MirageLogger.client("Stream recovery skipped (\(trigger.logLabel)) - not connected")
            return
        }
        guard let controller = controllersByStream[streamID] else {
            if trigger == .applicationActivation,
               desktopStreamID == streamID || activeStreams.contains(where: { $0.id == streamID }) {
                pendingApplicationActivationRecoveryStreamIDs.insert(streamID)
                MirageLogger.client(
                    "Stream recovery deferred (\(trigger.logLabel)) - controller missing for active stream \(streamID)"
                )
                return
            }
            MirageLogger.client(
                "Stream recovery skipped (\(trigger.logLabel)) - stream \(streamID) is no longer active"
            )
            return
        }

        if trigger == .applicationActivation,
           recoveryKeyframeRetryTasks[streamID] != nil {
            MirageLogger.client(
                "Stream recovery coalesced for stream \(streamID) trigger=\(trigger.logLabel)"
            )
            return
        }

        MirageLogger.client(
            "Stream recovery requested for stream \(streamID) trigger=\(trigger.logLabel)"
        )

        if trigger.clearsExistingFramesImmediately {
            MirageRenderStreamStore.shared.clear(for: streamID)
        }
        if trigger.requestsPresentationRecoveryImmediately {
            _ = MirageRenderStreamStore.shared.requestPresentationRecovery(for: streamID)
        }
        cancelRecoveryKeyframeRetry(for: streamID)
        if trigger.awaitFirstPresentedFrame {
            startRecoveryKeyframeRetry(for: streamID, controller: controller, trigger: trigger)
        }

        Task { [weak self] in
            guard let self else { return }
            await controller.requestRecovery(
                reason: .manualRecovery,
                awaitFirstPresentedFrame: trigger.awaitFirstPresentedFrame,
                firstPresentedFrameWaitReason: trigger.firstPresentedFrameWaitReason
            )
            sendKeyframeRequest(for: streamID)
        }
    }

}
