//
//  StreamController+Decoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream controller extensions.
//

import Foundation
import MirageKit

extension StreamController {
    // MARK: - Decoder Control

    /// Reset decoder for new session (e.g., after resize or reconnection)
    func resetForNewSession() async {
        // Drop any queued frames from the previous session to avoid BadData storms.
        stopFirstPresentedFrameMonitor()
        MirageFrameCache.shared.clear(for: streamID)
        stopFrameProcessingPipeline()
        await decoder.resetForNewSession()
        reassembler.reset()
        metricsTracker.reset()
        hasReceivedFirstFrame = false
        awaitingFirstFrameAfterResize = false
        decodePausedForLocalResize = false
        lastMetricsLogTime = 0
        lastDecodedFrameTime = 0
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        stopFreezeMonitor()
        await startFrameProcessingPipeline()
        armFirstPresentedFrameAwaiter(reason: "session-reset")
    }

    /// Freeze decode admission while local resize orchestration is in-flight.
    func suspendDecodeForLocalResize() {
        guard !decodePausedForLocalResize else { return }
        decodePausedForLocalResize = true
        clearQueuedFramesForRecovery()
        MirageLogger.client("Local resize decode pause enabled for stream \(streamID)")
    }

    /// Resume decode after local resize orchestration.
    /// Optionally requests an immediate recovery keyframe to reduce first-frame latency.
    func resumeDecodeAfterLocalResize(requestRecoveryKeyframe: Bool) async {
        if decodePausedForLocalResize {
            decodePausedForLocalResize = false
            MirageLogger.client("Local resize decode pause cleared for stream \(streamID)")
        }

        guard requestRecoveryKeyframe else { return }
        beginPostResizeTransition()
        await requestKeyframeRecovery(reason: .manualRecovery)
    }

    /// Enter keyframe-only decode admission until a post-resize first frame is decoded.
    func beginPostResizeTransition() {
        guard !awaitingFirstFrameAfterResize else { return }
        awaitingFirstFrameAfterResize = true
        clearQueuedFramesForRecovery()
        reassembler.enterKeyframeOnlyMode()
        armFirstPresentedFrameAwaiter(reason: "post-resize")
        MirageLogger.client("Post-resize transition armed for stream \(streamID) (keyframe-only decode admission)")
    }

    func logMetricsIfNeeded(decodedFPS: Double, receivedFPS: Double, droppedFrames: UInt64) {
        let now = currentTime()
        guard MirageLogger.isEnabled(.client) else { return }
        guard lastMetricsLogTime == 0 || now - lastMetricsLogTime > 2.0 else { return }
        let decodedText = decodedFPS.formatted(.number.precision(.fractionLength(1)))
        let receivedText = receivedFPS.formatted(.number.precision(.fractionLength(1)))
        MirageLogger
            .client(
                "Client FPS: decoded=\(decodedText), received=\(receivedText), dropped=\(droppedFrames), stream=\(streamID)"
            )
        lastMetricsLogTime = now
    }

    /// Get the reassembler for packet routing
    func getReassembler() -> FrameReassembler {
        reassembler
    }

    func updateDecodeSubmissionLimit(targetFrameRate: Int) async {
        decodeSchedulerTargetFPS = MirageRenderModePolicy.normalizedTargetFPS(targetFrameRate)
        decodeSubmissionBaselineLimit = HEVCDecoder.baselineDecodeSubmissionLimit(targetFrameRate: decodeSchedulerTargetFPS)
        decodeSubmissionStressStreak = 0
        decodeSubmissionHealthyStreak = 0
        currentDecodeSubmissionLimit = decodeSubmissionBaselineLimit
        await decoder.setDecodeSubmissionLimit(limit: decodeSubmissionBaselineLimit, reason: "target refresh update")
    }
}
