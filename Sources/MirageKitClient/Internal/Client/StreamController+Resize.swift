//
//  StreamController+Resize.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream controller extensions.
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
import CoreVideo
import Foundation

extension StreamController {
    // MARK: - Resize Handling

    /// Force clear resize state (e.g., when returning from background)
    func clearResizeState() async {
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        await setResizeState(.idle)
    }

    /// Request stream recovery (keyframe + reassembler reset)
    func requestRecovery(
        reason: RecoveryReason = .manualRecovery,
        restartRecoveryLoop: Bool = true,
        awaitFirstPresentedFrame: Bool = false,
        firstPresentedFrameWaitReason: String? = nil
    )
    async {
        guard !isStopping else {
            MirageLogger.client(
                "Skipping stream recovery (\(reason.logLabel)) for stopping stream \(streamID)"
            )
            stopFirstPresentedFrameMonitor()
            resetPostResizeRecoveryTracking(clearResizeRecovery: true)
            await clearKeyframeRecoveryState()
            await setClientRecoveryStatus(.idle)
            return
        }
        guard !hasTriggeredTerminalStartupFailure else { return }
        let shouldRestartStartupBootstrap = !hasPresentedFirstFrame
        let shouldAwaitNextPresentedFrame = shouldRestartStartupBootstrap || awaitFirstPresentedFrame
        let now = currentTime
        if reason != .manualRecovery,
           !Self.shouldDispatchRecovery(
               lastDispatchTime: lastHardRecoveryStartTime,
               now: now,
               minimumInterval: Self.hardRecoveryMinimumInterval
           ) {
            let lastTime = lastHardRecoveryStartTime
            let remainingMs = Int(
                ((Self.hardRecoveryMinimumInterval - (now - lastTime)) * 1000)
                    .rounded(.up)
            )
            MirageLogger
                .client(
                    "Hard recovery throttled (\(reason.logLabel), \(max(0, remainingMs))ms remaining) for stream \(streamID)"
                )
            if reason == .decodeErrorThreshold {
                reassembler.beginKeyframeWait()
            }
            if restartRecoveryLoop, presentationTier == .activeLive {
                await enterKeyframeRecoveryIfNeeded(
                    reason: "hard-recovery-throttled-\(reason.logLabel)",
                    cause: reason.recoveryCause
                )
            }
            await requestKeyframeRecoveryIfPossible(reason: reason)
            return
        }

        if shouldRestartStartupBootstrap {
            if startupHardRecoveryCount >= Self.startupHardRecoveryLimit {
                await failStartupRecovery(reason: reason)
                return
            }
            startupHardRecoveryCount += 1
        }
        lastHardRecoveryStartTime = now

        MirageLogger.client("Starting stream recovery (\(reason.logLabel)) for stream \(streamID)")
        await setClientRecoveryStatus(.hardRecovery, cause: reason.recoveryCause)
        await clearResizeState()
        decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
        MirageRenderStreamStore.shared.clear(for: streamID)
        _ = MirageRenderStreamStore.shared.requestPresentationRecovery(for: streamID)
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        lastDecodedProgressTime = 0
        presentationProgressRequiresSequenceAdvance = shouldAwaitNextPresentedFrame
        resetPostResizeRecoveryTracking(clearResizeRecovery: true)
        lastFreezeRecoveryTime = 0
        consecutiveFreezeRecoveries = 0
        stopFrameProcessingPipeline()
        await decoder.resetForNewSession()
        reassembler.reset()
        if shouldRestartStartupBootstrap {
            stopFirstPresentedFrameMonitor()
            hasDecodedFirstFrame = false
            hasPresentedFirstFrame = false
        }
        reassembler.beginKeyframeWait()
        if restartRecoveryLoop, presentationTier == .activeLive {
            await enterKeyframeRecoveryIfNeeded(reason: "hard-\(reason.logLabel)", cause: reason.recoveryCause)
        } else {
            await clearKeyframeRecoveryState()
        }
        await startFrameProcessingPipeline()
        if shouldAwaitNextPresentedFrame, presentationTier == .activeLive {
            let awaitMode: FirstPresentedFrameAwaitMode = shouldRestartStartupBootstrap ? .startup : .recovery
            await armFirstPresentedFrameAwaiter(
                reason: firstPresentedFrameWaitReason ?? "hard-recovery",
                mode: awaitMode
            )
        }
        await requestKeyframeRecoveryIfPossible(reason: reason)
    }
}
