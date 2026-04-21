//
//  StreamController+Resize.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream controller extensions.
//

import CoreVideo
import Foundation
import MirageKit

extension StreamController {
    // MARK: - Resize Handling

    /// Handle drawable size change from Metal layer
    /// - Parameters:
    ///   - pixelSize: New drawable size in pixels
    ///   - screenBounds: Screen bounds in points
    ///   - scaleFactor: Screen scale factor
    func handleDrawableSizeChanged(
        _ pixelSize: CGSize,
        screenBounds: CGSize,
        scaleFactor: CGFloat
    )
    async {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }

        // Only enter resize mode after first frame
        if hasPresentedFirstFrame { await setResizeState(.awaiting(expectedSize: pixelSize)) }

        // Cancel pending debounce
        resizeDebounceTask?.cancel()

        // Debounce resize
        resizeDebounceTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: Self.resizeDebounceDelay)
            } catch {
                return // Cancelled
            }

            await processResizeEvent(pixelSize: pixelSize, screenBounds: screenBounds, scaleFactor: scaleFactor)
        }
    }

    /// Called when host confirms resize (sends new min size)
    func confirmResize(newMinSize: CGSize) async {
        if case .awaiting = resizeState {
            await setResizeState(.confirmed(finalSize: newMinSize))
            // Brief delay then return to idle
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                await self?.setResizeState(.idle)
            }
        }
    }

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
            await stopKeyframeRecoveryLoop()
            await setClientRecoveryStatus(.idle)
            return
        }
        guard !hasTriggeredTerminalStartupFailure else { return }
        let shouldRestartStartupBootstrap = !hasPresentedFirstFrame
        let shouldAwaitNextPresentedFrame = shouldRestartStartupBootstrap || awaitFirstPresentedFrame
        let now = currentTime()
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
            if restartRecoveryLoop, presentationTier == .activeLive {
                await startKeyframeRecoveryLoopIfNeeded()
            }
            await requestKeyframeRecovery(reason: reason)
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
        await setClientRecoveryStatus(.hardRecovery)
        await clearResizeState()
        decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
        MirageRenderStreamStore.shared.clear(for: streamID)
        lastDecodedFrameTime = 0
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
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
        reassembler.enterKeyframeOnlyMode()
        if restartRecoveryLoop, presentationTier == .activeLive {
            await startKeyframeRecoveryLoopIfNeeded()
        } else {
            await stopKeyframeRecoveryLoop()
        }
        await startFrameProcessingPipeline()
        if shouldAwaitNextPresentedFrame, presentationTier == .activeLive {
            let awaitMode: FirstPresentedFrameAwaitMode = shouldRestartStartupBootstrap ? .startup : .recovery
            await armFirstPresentedFrameAwaiter(
                reason: firstPresentedFrameWaitReason ?? "hard-recovery",
                mode: awaitMode
            )
        }
        await requestKeyframeRecovery(reason: reason)
    }
}
