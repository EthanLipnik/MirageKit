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
        hasDecodedFirstFrame = false
        hasPresentedFirstFrame = false
        awaitingFirstFrameAfterResize = false
        decodePausedForLocalResize = false
        lastMetricsLogTime = 0
        lastDecodedFrameTime = 0
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        stopFreezeMonitor()
        await startFrameProcessingPipeline()
        if presentationTier == .activeLive {
            armFirstPresentedFrameAwaiter(reason: "session-reset")
        } else {
            stopFirstPresentedFrameMonitor()
        }
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

    func updatePresentationTier(_ tier: StreamPresentationTier) async {
        let previousTier = presentationTier
        presentationTier = tier

        let targetFPS = tier == .activeLive ? 60 : 4
        decodeSchedulerTargetFPS = targetFPS
        decodeSubmissionBaselineLimit = HEVCDecoder.baselineDecodeSubmissionLimit(targetFrameRate: targetFPS)
        decodeSubmissionStressStreak = 0
        decodeSubmissionHealthyStreak = 0
        currentDecodeSubmissionLimit = max(1, decodeSubmissionBaselineLimit)
        await decoder.setDecodeSubmissionLimit(limit: currentDecodeSubmissionLimit, reason: "presentation tier update")

        switch tier {
        case .activeLive:
            if !hasPresentedFirstFrame {
                armFirstPresentedFrameAwaiter(reason: "tier-promotion")
            }
            if previousTier == .passiveSnapshot {
                reassembler.enterKeyframeOnlyMode()
                startKeyframeRecoveryLoopIfNeeded()
                await requestKeyframeRecovery(reason: .manualRecovery)
            }
        case .passiveSnapshot:
            if !hasPresentedFirstFrame {
                stopFirstPresentedFrameMonitor()
            }
        }
    }
}
