//
//  StreamController+PostResizeRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

extension StreamController {
    /// Returns whether decode errors should be ignored during the post-resize grace window.
    nonisolated static func shouldSuppressPostResizeDecodeErrorRecovery(
        awaitingFirstFrameAfterResize: Bool,
        graceDeadline: CFAbsoluteTime,
        now: CFAbsoluteTime
    ) -> Bool {
        awaitingFirstFrameAfterResize && graceDeadline > 0 && now < graceDeadline
    }

    /// Resets post-resize recovery counters and optionally clears the active resize recovery gate.
    func resetPostResizeRecoveryTracking(clearResizeRecovery: Bool) {
        postResizeDecodeRecoverySuccessCount = 0
        if clearResizeRecovery {
            awaitingFirstFrameAfterResize = false
            awaitingFirstPresentedFrameAfterResize = false
            postResizeDecodeErrorGraceDeadline = 0
        }
    }

    /// Arms the recovery window used after a host-side resize or stream dimension reset.
    func armPostResizeRecoveryWindow(reason: String) async {
        postResizeRecoveryEpisodeID &+= 1
        awaitingFirstFrameAfterResize = true
        awaitingFirstPresentedFrameAfterResize = true
        postResizeDecodeRecoverySuccessCount = 0
        postResizeDecodeErrorGraceDeadline = currentTime + Self.postResizeDecodeErrorGraceInterval
        await decoder.beginRecoveryTracking()
        await setClientRecoveryStatus(.postResizeAwaitingFirstFrame)
        if presentationTier == .activeLive {
            await armFirstPresentedFrameAwaiter(reason: reason, mode: .recovery)
        }
    }

    /// Records that decoder recovery succeeded for the active post-resize episode.
    func handleDecoderRecoverySignal() async {
        guard awaitingFirstFrameAfterResize else { return }
        postResizeDecodeRecoverySuccessCount = Self.postResizeDecodeRecoverySuccessThreshold
        MirageLogger.client(
            "Post-resize decoder recovery streak complete for stream \(streamID)"
        )
        await maybeCompletePostResizeRecovery()
    }

    /// Clears post-resize recovery once decode and presentation gates have both completed.
    func maybeCompletePostResizeRecovery() async {
        guard awaitingFirstFrameAfterResize else { return }
        guard !awaitingFirstPresentedFrameAfterResize else { return }
        guard postResizeDecodeRecoverySuccessCount >= Self.postResizeDecodeRecoverySuccessThreshold else { return }
        awaitingFirstFrameAfterResize = false
        postResizeDecodeErrorGraceDeadline = 0
        MirageLogger.client("Post-resize recovery stabilized for stream \(streamID)")
        if clientRecoveryStatus == .postResizeAwaitingFirstFrame {
            await setClientRecoveryStatus(.idle)
        }
    }

    /// Clears transient recovery state after verified presentation progress resumes.
    func clearTransientRecoveryStateAfterPresentationProgress() async {
        cancelMemoryBudgetRecoveryTask()
        recoveryCoordinator.recordProgress()
        guard Self.shouldClearRecoveryStatusOnPresentationProgress(clientRecoveryStatus) else { return }

        switch clientRecoveryStatus {
        case .keyframeRecovery:
            MirageLogger.client(
                "Presentation progress resumed for stream \(streamID); ending keyframe recovery"
            )
            await clearKeyframeRecoveryState()
        case .hardRecovery:
            MirageLogger.client(
                "Presentation progress resumed for stream \(streamID); ending hard recovery"
            )
            presentationProgressRequiresSequenceAdvance = false
            await clearKeyframeRecoveryState()
            await setClientRecoveryStatus(.idle)
        case .tierPromotionProbe:
            MirageLogger.client(
                "Presentation progress resumed for stream \(streamID); ending tier-promotion probe"
            )
            await stopTierPromotionProbe()
        case .idle,
             .startup,
             .postResizeAwaitingFirstFrame:
            break
        }
    }

    /// Records a decoded frame and advances startup, post-resize, and freeze-monitor recovery gates.
    func recordDecodedFrame() async {
        lastDecodedProgressTime = currentTime
        if !decodeRecoveryEscalationTimestamps.isEmpty {
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
        }
        if awaitingFirstFrameAfterResize {
            let shouldNotify = postResizeDecodeRecoverySuccessCount == 0
            postResizeDecodeRecoverySuccessCount = min(
                Self.postResizeDecodeRecoverySuccessThreshold,
                postResizeDecodeRecoverySuccessCount + 1
            )
            if shouldNotify {
                MirageLogger.client("Post-resize decoded frame arrived for stream \(streamID)")
            }
            if postResizeDecodeRecoverySuccessCount >= Self.postResizeDecodeRecoverySuccessThreshold {
                awaitingFirstPresentedFrameAfterResize = false
                await maybeCompletePostResizeRecovery()
            }
        }
        if presentationTier == .activeLive,
           !hasPresentedFirstFrame,
           !awaitingFirstPresentedFrame {
            await armFirstPresentedFrameAwaiter(reason: "decode-without-presentation")
        }
        if presentationTier == .activeLive {
            startFreezeMonitorIfNeeded()
        } else {
            stopFreezeMonitor()
            lastPresentedProgressTime = currentTime
            consecutiveFreezeRecoveries = 0
        }
    }
}
