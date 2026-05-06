//
//  StreamContext+LatencyBurst.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/6/26.
//
//  Freshness-first latency burst delivery policy.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    func resolvedQualityCeiling() -> Float {
        min(steadyQualityCeiling, compressionQualityCeiling)
    }

    func enterLatencyBurst(now: CFAbsoluteTime, reason: String) async {
        let clearedBacklog = frameInbox.clear()
        if clearedBacklog > 0 {
            MirageLogger.metrics(
                "Latency burst cleared \(clearedBacklog) buffered frames for stream \(streamID)"
            )
        }

        if !latencyBurstActive {
            latencyBurstActive = true
            latencyBurstDrainsNewestFrames = true
            preLatencyBurstCaptureQueueDepthOverride = encoderConfig.captureQueueDepth
            latencyBurstCaptureQueueDepthOverride = latencyBurstCaptureQueueDepth

            do {
                try await updateLatencyBurstCaptureQueueDepthOverride(
                    latencyBurstCaptureQueueDepth,
                    reason: reason
                )
            } catch {
                MirageLogger.error(
                    .stream,
                    error: error,
                    message: "Failed to apply latency burst capture queue override: "
                )
            }
        }

        await packetSender?.resetQueue(reason: "\(reason) queue reset")
        clearBackpressureState(log: false)
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0

        if queueKeyframe(
            reason: "Latency burst recovery keyframe",
            checkInFlight: false,
            urgent: true
        ) {
            noteLossEvent(reason: "latency burst", enablePFrameFEC: true)
            markKeyframeRequestIssued()
            scheduleProcessingIfNeeded()
        }

        let queueDepthText = latencyBurstCaptureQueueDepthOverride.map(String.init) ?? "default"
        MirageLogger.metrics(
            "Latency burst entered for stream \(streamID): reason=\(reason), queueDepth=\(queueDepthText), bufferedClears=\(clearedBacklog)"
        )
    }

    func exitLatencyBurst(now: CFAbsoluteTime, reason: String) async {
        guard latencyBurstActive else { return }

        latencyBurstActive = false
        latencyBurstDrainsNewestFrames = false

        let restoredQueueDepth = preLatencyBurstCaptureQueueDepthOverride
        do {
            try await updateLatencyBurstCaptureQueueDepthOverride(
                restoredQueueDepth,
                reason: "\(reason) restore"
            )
        } catch {
            MirageLogger.error(
                .stream,
                error: error,
                message: "Failed to restore latency burst capture queue override: "
            )
        }

        preLatencyBurstCaptureQueueDepthOverride = nil
        latencyBurstCaptureQueueDepthOverride = nil

        let restoredQueueDepthText = restoredQueueDepth.map(String.init) ?? "default"
        MirageLogger.metrics(
            "Latency burst exited for stream \(streamID): reason=\(reason), restoredQueueDepth=\(restoredQueueDepthText), inFlight=\(maxInFlightFrames)"
        )

        qualityCeiling = resolvedQualityCeiling()
        lastInFlightAdjustmentTime = now
    }

    func updateLatencyBurstCaptureQueueDepthOverride(
        _ overrideDepth: Int?,
        reason: String
    ) async throws {
        var updatedConfig = encoderConfig
        updatedConfig.captureQueueDepth = overrideDepth
        guard updatedConfig.captureQueueDepth != encoderConfig.captureQueueDepth else { return }

        if let captureEngine {
            try await captureEngine.updateConfiguration(updatedConfig)
        }
        encoderConfig = updatedConfig

        let queueDepthText = overrideDepth.map(String.init) ?? "default"
        MirageLogger.metrics(
            "Latency burst capture queue override updated for stream \(streamID): queueDepth=\(queueDepthText), reason=\(reason)"
        )
    }
}
#endif
