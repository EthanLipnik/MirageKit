//
//  StreamController+Recovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

extension StreamController {
    /// Returns whether presentation progress should clear the visible recovery status.
    nonisolated static func shouldClearRecoveryStatusOnPresentationProgress(
        _ status: MirageStreamClientRecoveryStatus
    ) -> Bool {
        switch status {
        case .tierPromotionProbe,
             .keyframeRecovery,
             .hardRecovery:
            true
        case .idle,
             .startup,
             .postResizeAwaitingFirstFrame:
            false
        }
    }

    /// Records a local decode-queue drop for metrics and rate-limited logging.
    func recordQueueDrop() {
        queueDropsSinceLastLog += 1
        metricsTracker.recordQueueDrop()
    }

    /// Emits a decode-queue drop log when the rate limit allows it.
    func logQueueDropIfNeeded() {
        let now = currentTime
        if now - lastQueueDropLogTime >= Self.queueDropLogInterval {
            lastQueueDropLogTime = now
            let dropped = queueDropsSinceLastLog
            queueDropsSinceLastLog = 0
            MirageLogger.client(
                "Decode backpressure: dropped \(dropped) frames (depth \(queuedFrames.count)) for stream \(streamID)"
            )
        }
    }

    /// Logs a decode backpressure threshold event without forcing keyframe recovery.
    func maybeLogDecodeBackpressure(queueDepth: Int) {
        let now = currentTime
        if lastBackpressureLogTime > 0,
           now - lastBackpressureLogTime < Self.backpressureLogCooldown {
            return
        }
        lastBackpressureLogTime = now
        MirageLogger.client(
            "Decode backpressure threshold hit (depth \(queueDepth)) for stream \(streamID); " +
                "continuing decode without keyframe recovery"
        )
    }

    /// Handles frame reassembly loss by choosing bootstrap, passive, immediate, or delayed recovery.
    func handleFrameLossSignal(
        reason: FrameReassembler.FrameLossReason = .timeout
    ) async {
        if let diagnostic = Self.frameLossDiagnosticMessage(streamID: streamID, reason: reason) {
            MirageLogger.client(diagnostic)
        }
        if reason == .severeForwardGap {
            let metricsSnapshot = metricsTracker.snapshot(now: currentTime)
            await maybeLogStreamingAnomalyDiagnostic(
                trigger: "frame-loss-\(reason.rawValue)",
                decodedFPS: metricsSnapshot.decodedFPS,
                receivedFPS: metricsSnapshot.receivedFPS
            )
        }
        if !hasDecodedFirstFrame || !hasPresentedFirstFrame {
            if presentationTier == .activeLive, !awaitingFirstPresentedFrame {
                await armFirstPresentedFrameAwaiter(reason: "frame-loss-bootstrap")
            }
            let now = currentTime
            firstPresentedFrameLastRecoveryRequestTime = now
            firstPresentedFrameRecoveryAttemptCount = max(1, firstPresentedFrameRecoveryAttemptCount)
            MirageLogger.client(
                "Frame loss detected before first frame for stream \(streamID) reason=\(reason.rawValue); requesting bootstrap recovery keyframe"
            )
            await requestKeyframeRecoveryIfPossible(reason: .startupKeyframeTimeout)
            return
        }

        if presentationTier == .passiveSnapshot {
            reassembler.beginKeyframeWait()
            MirageLogger.client(
                "Frame loss detected for passive stream \(streamID); requesting recovery keyframe"
            )
            await requestKeyframeRecoveryIfPossible(reason: .frameLoss)
            return
        }

        if reason.requestsImmediateActiveRecovery {
            reassembler.beginKeyframeWait()
            MirageLogger.client(
                "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); requesting immediate recovery keyframe"
            )
            await startKeyframeRecoveryLoopIfNeeded()
            await requestKeyframeRecoveryIfPossible(reason: .frameLoss)
            return
        }

        if reason == .memoryBudget {
            reassembler.beginKeyframeWait()
            discardQueuedFramesForRecovery()
            startFreezeMonitorIfNeeded()
            if memoryBudgetRecoveryTask != nil {
                MirageLogger.client(
                    "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); " +
                        "memory-budget recovery already settling"
                )
                return
            }
            scheduleMemoryBudgetRecoveryIfNeeded()
            MirageLogger.client(
                "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); deferring recovery keyframe while memory pressure settles"
            )
            return
        }

        if reason == .timeout, reassembler.isAwaitingKeyframe {
            guard !hasPresentedFirstFrame else {
                startFreezeMonitorIfNeeded()
                let pendingFrameCount = MirageRenderStreamStore.shared.pendingFrameCount(for: streamID)
                let pendingFrameAgeMs = MirageRenderStreamStore.shared.pendingFrameAgeMs(for: streamID)
                let clearedRenderFrames = pendingFrameAgeMs >= Self.stalePendingRenderFrameRecoveryAgeMs
                    ? MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
                    : 0
                discardQueuedFramesForRecovery()
                MirageLogger.client(
                    "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); " +
                        "reassembler is awaiting keyframe after presentation progress, " +
                        "requesting bounded recovery keyframe " +
                        "(pendingRenderFrames=\(pendingFrameCount), pendingAge=\(Int(pendingFrameAgeMs.rounded()))ms, " +
                        "clearedRenderFrames=\(clearedRenderFrames))"
                )
                await startKeyframeRecoveryLoopIfNeeded()
                await requestKeyframeRecoveryIfPossible(reason: .frameLoss)
                return
            }
            MirageLogger.client(
                "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); " +
                    "reassembler is awaiting keyframe before first presentation, requesting bounded recovery"
            )
            await startKeyframeRecoveryLoopIfNeeded()
            await requestKeyframeRecoveryIfPossible(reason: .frameLoss)
            return
        }

        // Active streams avoid keyframe requests for non-blocking packet loss.
        // Once the reassembler enters keyframe wait, the timeout branch above
        // requests bounded recovery because dependent P-frames cannot resume decoding.
        MirageLogger.client(
            "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); waiting for natural keyframe or decode error"
        )
    }

    func cancelMemoryBudgetRecoveryTask() {
        memoryBudgetRecoveryTask?.cancel()
        memoryBudgetRecoveryTask = nil
    }

    func requestKeyframeRecoveryIfPossible(reason: RecoveryReason) async {
        _ = await requestKeyframeRecovery(reason: reason)
    }

    func requestKeyframeRecovery(reason: RecoveryReason) async -> Bool {
        let now = currentTime
        let coalesceInterval = Self.keyframeRequestCoalesceInterval(targetFPS: decodeSchedulerTargetFPS)
        if lastRecoveryRequestDispatchTime > 0,
           now - lastRecoveryRequestDispatchTime < coalesceInterval {
            return false
        }
        if shouldDeferKeyframeRequestForPendingProgress(now: now, reason: reason) {
            return false
        }
        let recoveryDecision = recoveryCoordinator.requestAction(
            now: now,
            reason: reason.logLabel,
            targetFPS: decodeSchedulerTargetFPS,
            forceNewEpisode: reason == .manualRecovery ||
                reason == .decodeErrorThreshold
        )
        switch recoveryDecision {
        case .dispatch:
            break
        case let .wait(deadline):
            let remainingMs = Int(max(0, deadline - now) * 1000)
            MirageLogger.client(
                "Recovery keyframe deferred until retry deadline " +
                    "(\(reason.logLabel), \(remainingMs)ms remaining) for stream \(streamID)"
            )
            return false
        }
        guard let handler = onKeyframeNeeded else {
            recoveryCoordinator.recordDispatchNotSent()
            return false
        }
        MirageLogger.client("Requesting recovery keyframe (\(reason.logLabel)) for stream \(streamID)")
        let didSend = await MainActor.run {
            handler()
        }
        guard didSend else {
            recoveryCoordinator.recordDispatchNotSent()
            MirageLogger.client("Recovery keyframe request not sent by client service for stream \(streamID)")
            return false
        }
        if keyframeRecoveryTask != nil, reason != .keyframeRecoveryLoop {
            keyframeRecoveryAttempt = max(1, keyframeRecoveryAttempt)
        }
        lastRecoveryRequestDispatchTime = now
        lastRecoveryRequestTime = now
        return true
    }

    private func shouldDeferKeyframeRequestForPendingProgress(
        now: CFAbsoluteTime,
        reason: RecoveryReason
    ) -> Bool {
        guard reason != .manualRecovery else { return false }
        guard let pendingKeyframeProgress = reassembler.latestPendingKeyframeProgress else {
            return false
        }
        return Self.shouldDeferForPendingKeyframeProgress(
            pendingKeyframeProgress,
            now: now,
            targetFPS: decodeSchedulerTargetFPS
        )
    }

    func handleDecodeErrorThresholdSignal() async {
        guard !hasTriggeredTerminalStartupFailure else { return }
        if awaitingFirstFrameAfterResize {
            resetPostResizeRecoveryTracking(clearResizeRecovery: false)
        }

        if presentationTier == .passiveSnapshot {
            await requestSoftRecovery(reason: .decodeErrorThreshold)
            return
        }

        let now = currentTime
        if Self.shouldSuppressPostResizeDecodeErrorRecovery(
            awaitingFirstFrameAfterResize: awaitingFirstFrameAfterResize,
            graceDeadline: postResizeDecodeErrorGraceDeadline,
            now: now
        ) {
            return
        }
        if awaitingFirstFrameAfterResize {
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
            MirageLogger.client(
                "Post-resize decode error threshold exceeded after grace for stream \(streamID); requesting immediate soft recovery"
            )
            await requestSoftRecovery(reason: .decodeErrorThreshold)
            return
        }
        decodeRecoveryEscalationTimestamps.append(now)
        trimDecodeRecoveryEscalationWindow(now: now)

        let shouldEscalate = decodeRecoveryEscalationTimestamps.count >= Self.decodeRecoveryEscalationThreshold
        if shouldEscalate {
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
            MirageLogger.client(
                "Decode error storm persisted for stream \(streamID); escalating to hard recovery"
            )
            await requestRecovery(
                reason: .decodeErrorThreshold,
                awaitFirstPresentedFrame: presentationTier == .activeLive,
                firstPresentedFrameWaitReason: "decode-error-hard-reset"
            )
            return
        }

        if awaitingFirstPresentedFrame {
            firstPresentedFrameLastRecoveryRequestTime = now
            MirageLogger.client(
                "Decode error threshold observed while awaiting presentation for stream \(streamID); requesting immediate recovery keyframe"
            )
        }
        await requestSoftRecovery(reason: .decodeErrorThreshold)
    }

    func failStartupRecovery(reason: RecoveryReason) async {
        guard !hasTriggeredTerminalStartupFailure else { return }

        let failure = TerminalStartupFailure(
            reason: reason,
            hardRecoveryAttempts: startupHardRecoveryCount,
            waitReason: firstPresentedFrameWaitReason
        )
        let waitReason = failure.waitReason ?? "unknown"

        hasTriggeredTerminalStartupFailure = true
        isRunning = false
        stopFrameProcessingPipeline()
        stopMetricsReporting()
        stopFreezeMonitor()
        await stopTierPromotionProbe()
        await stopKeyframeRecoveryLoop()
        stopFirstPresentedFrameMonitor()
        await setClientRecoveryStatus(.idle)

        MirageLogger.error(
            .client,
            "Startup recovery exhausted for stream \(streamID) after \(failure.hardRecoveryAttempts) hard recovery attempt(s) " +
                "(reason=\(failure.reason.logLabel), waitReason=\(waitReason))"
        )

        guard let onTerminalStartupFailure else { return }
        await MainActor.run {
            onTerminalStartupFailure(failure)
        }
    }

    func shouldAttemptDecodeErrorRecovery(now: CFAbsoluteTime) -> Bool {
        if presentationTier == .passiveSnapshot { return true }
        return !Self.shouldSuppressPostResizeDecodeErrorRecovery(
            awaitingFirstFrameAfterResize: awaitingFirstFrameAfterResize,
            graceDeadline: postResizeDecodeErrorGraceDeadline,
            now: now
        )
    }

    private func trimDecodeRecoveryEscalationWindow(now: CFAbsoluteTime) {
        let oldestAllowed = now - Self.decodeRecoveryEscalationWindow
        decodeRecoveryEscalationTimestamps.removeAll { $0 < oldestAllowed }
    }

    nonisolated static func isStalePostResizeSoftRecoveryRequest(
        capturedEpisodeID: UInt64?,
        currentEpisodeID: UInt64,
        awaitingFirstFrameAfterResize: Bool
    ) -> Bool {
        guard let capturedEpisodeID else { return false }
        return !awaitingFirstFrameAfterResize || currentEpisodeID != capturedEpisodeID
    }

    func requestSoftRecovery(reason: RecoveryReason) async {
        let now = currentTime
        let capturedPostResizeRecoveryEpisodeID = awaitingFirstFrameAfterResize ? postResizeRecoveryEpisodeID : nil
        if !Self.shouldDispatchRecovery(
            lastDispatchTime: lastSoftRecoveryRequestTime,
            now: now,
            minimumInterval: Self.softRecoveryMinimumInterval
        ) {
            let lastTime = lastSoftRecoveryRequestTime
            let remainingMs = Int(
                ((Self.softRecoveryMinimumInterval - (now - lastTime)) * 1000)
                    .rounded(.up)
            )
            MirageLogger
                .client(
                    "Soft recovery throttled (\(reason.logLabel), \(max(0, remainingMs))ms remaining) for stream \(streamID)"
                )
            if presentationTier == .activeLive {
                await startKeyframeRecoveryLoopIfNeeded()
            }
            if reason == .decodeErrorThreshold {
                discardQueuedFramesForRecovery()
                reassembler.beginKeyframeWait()
                await requestKeyframeRecoveryIfPossible(reason: reason)
            }
            return
        }
        lastSoftRecoveryRequestTime = now

        MirageLogger.client("Starting soft stream recovery (\(reason.logLabel)) for stream \(streamID)")
        if clientRecoveryStatus != .postResizeAwaitingFirstFrame,
           clientRecoveryStatus != .hardRecovery {
            await setClientRecoveryStatus(.keyframeRecovery)
        }
        await clearResizeState()
        let postResizeRecoveryActive = capturedPostResizeRecoveryEpisodeID != nil &&
            !Self.isStalePostResizeSoftRecoveryRequest(
                capturedEpisodeID: capturedPostResizeRecoveryEpisodeID,
                currentEpisodeID: postResizeRecoveryEpisodeID,
                awaitingFirstFrameAfterResize: awaitingFirstFrameAfterResize
            )
        if capturedPostResizeRecoveryEpisodeID != nil, !postResizeRecoveryActive {
            MirageLogger.client(
                "Skipping stale post-resize soft recovery follow-up for stream \(streamID)"
            )
            return
        }
        if postResizeRecoveryActive {
            resetPostResizeRecoveryTracking(clearResizeRecovery: false)
        }
        discardQueuedFramesForRecovery()
        reassembler.trimPendingFramesForRecovery(reason: reason.logLabel)
        reassembler.beginKeyframeWait()
        if postResizeRecoveryActive {
            await armPostResizeRecoveryWindow(reason: "post-resize-soft-recovery")
        }
        if presentationTier == .activeLive {
            await startKeyframeRecoveryLoopIfNeeded()
        }
        await requestKeyframeRecoveryIfPossible(reason: reason)
    }

    func resetStartupRecoveryTracking() {
        recoveryCoordinator.reset()
        resetTerminalStartupFailureTracking()
    }

    func resetTerminalStartupFailureTracking() {
        startupHardRecoveryCount = 0
        hasTriggeredTerminalStartupFailure = false
    }
}
