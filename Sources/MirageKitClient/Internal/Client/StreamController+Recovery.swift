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
    func recordQueueDrop(count: UInt64 = 1) {
        queueDropsSinceLastLog &+= count
        metricsTracker.recordQueueDrop(count: count)
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

    /// Logs a decode backpressure threshold event.
    func maybeLogDecodeBackpressure(queueDepth: Int) {
        let now = currentTime
        if lastBackpressureLogTime > 0,
           now - lastBackpressureLogTime < Self.backpressureLogCooldown {
            return
        }
        lastBackpressureLogTime = now
        MirageLogger.client(
            "Decode backpressure threshold hit (depth \(queueDepth)) for stream \(streamID)"
        )
    }

    /// Handles compressed-frame queue overflow without feeding dependent P-frames into VideoToolbox.
    func handleDecodeQueueDependencyBreak(droppedFrame: FrameData, queueDepth: Int) async {
        droppedFrame.releaseBuffer()
        let clearedQueuedFrames = clearQueuedDecodeFramesOnly()
        let droppedCount = UInt64(clearedQueuedFrames + 1)
        recordQueueDrop(count: droppedCount)
        maybeLogDecodeBackpressure(queueDepth: queueDepth)
        logQueueDropIfNeeded()

        decodeQueueRequiresKeyframe = true
        reassembler.beginKeyframeWait()
        startFreezeMonitorIfNeeded()

        MirageLogger.client(
            "Decode backpressure broke compressed-frame dependency chain for stream \(streamID); " +
                "droppedCurrent=1, clearedQueuedFrames=\(clearedQueuedFrames), requesting keyframe"
        )
        if presentationTier == .activeLive {
            await enterKeyframeRecoveryIfNeeded(reason: "decode-backpressure")
        }
        await requestKeyframeRecoveryIfPossible(reason: .frameLoss)
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
            await enterKeyframeRecoveryIfNeeded(reason: "frame-loss-\(reason.rawValue)")
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
                let now = currentTime
                let pendingFrameCount = MirageRenderStreamStore.shared.pendingFrameCount(for: streamID)
                let pendingFrameAgeMs = MirageRenderStreamStore.shared.pendingFrameAgeMs(for: streamID)
                if pendingFrameCount > 0 {
                    let pendingFrameIsFresh = pendingFrameAgeMs < Self.stalePendingRenderFrameRecoveryAgeMs
                    let didHandlePresenterPath = pendingFrameIsFresh
                        ? await maybeTriggerRenderSubmissionRecovery(
                            now: now,
                            pendingFrameCount: pendingFrameCount
                        )
                        : false
                    MirageLogger.client(
                        "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); " +
                            "reassembler is awaiting keyframe after presentation progress, " +
                            "routing pending render frames through presenter recovery " +
                            "(pendingRenderFrames=\(pendingFrameCount), pendingAge=\(Int(pendingFrameAgeMs.rounded()))ms, " +
                            "handled=\(didHandlePresenterPath))"
                    )
                    if didHandlePresenterPath { return }
                    let droppedPendingFrames = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
                    discardQueuedFramesForRecovery()
                    MirageLogger.client(
                        "Frame loss timeout for stream \(streamID) could not recover pending render frames; " +
                            "droppedPendingRenderFrames=\(droppedPendingFrames), requesting keyframe"
                    )
                    await enterKeyframeRecoveryIfNeeded(reason: "frame-loss-timeout-unhandled-pending-render")
                    await requestKeyframeRecoveryIfPossible(reason: .frameLoss)
                    return
                }
                discardQueuedFramesForRecovery()
                MirageLogger.client(
                    "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); " +
                        "reassembler is awaiting keyframe after presentation progress, " +
                        "waiting for freeze recovery or natural keyframe " +
                        "(pendingRenderFrames=\(pendingFrameCount), pendingAge=\(Int(pendingFrameAgeMs.rounded()))ms)"
                )
                return
            }
            MirageLogger.client(
                "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); " +
                    "reassembler is awaiting keyframe before first presentation, requesting bounded recovery"
            )
            await enterKeyframeRecoveryIfNeeded(reason: "frame-loss-timeout-before-first-presentation")
            await requestKeyframeRecoveryIfPossible(reason: .frameLoss)
            return
        }

        if reason == .timeout,
           await maybeRecoverStalledActiveFrameLossTimeout() {
            return
        }
        if reason == .timeout,
           presentationTier == .activeLive,
           hasPresentedFirstFrame {
            let snapshot = reassembler.keyframeWaitSnapshot
            reassembler.beginKeyframeWait()
            discardQueuedFramesForRecovery()
            MirageLogger.client(
                "Frame loss timeout for stream \(streamID) had no presenter recovery path; " +
                    "requesting one recovery keyframe (path=\(snapshot.transportPathKind.rawValue))"
            )
            await enterKeyframeRecoveryIfNeeded(reason: "frame-loss-timeout-unhandled")
            await requestKeyframeRecoveryIfPossible(reason: .frameLoss)
            return
        }

        // Active streams avoid keyframe requests for non-blocking packet loss
        // while decoded or presented frames are still making progress.
        MirageLogger.client(
            "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); waiting for natural keyframe or decode error"
        )
    }

    func maybeRecoverStalledActiveFrameLossTimeout() async -> Bool {
        guard presentationTier == .activeLive,
              hasPresentedFirstFrame else {
            return false
        }

        let now = currentTime
        startFreezeMonitorIfNeeded()
        _ = syncPresentationProgressFromFrameStore(now: now)

        let pendingFrameCount = MirageRenderStreamStore.shared.pendingFrameCount(for: streamID)
        if pendingFrameCount > 0 {
            let pendingFrameAgeMs = MirageRenderStreamStore.shared.pendingFrameAgeMs(for: streamID)
            let pendingFrameIsFresh = pendingFrameAgeMs < Self.stalePendingRenderFrameRecoveryAgeMs
            let didHandlePresenterPath = pendingFrameIsFresh
                ? await maybeTriggerRenderSubmissionRecovery(
                    now: now,
                    pendingFrameCount: pendingFrameCount
                )
                : false
            MirageLogger.client(
                "Frame loss timeout for stream \(streamID) found pending render frames; " +
                    "routing through presenter recovery " +
                    "(pendingRenderFrames=\(pendingFrameCount), pendingAge=\(Int(pendingFrameAgeMs.rounded()))ms, " +
                    "handled=\(didHandlePresenterPath))"
            )
            if !didHandlePresenterPath {
                _ = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
            }
            return didHandlePresenterPath
        }

        let snapshot = reassembler.keyframeWaitSnapshot
        let usefulProgressTime = max(lastDecodedProgressTime, lastPresentedProgressTime)
        guard usefulProgressTime > 0 else {
            return false
        }

        let noUsefulProgressDuration = now - usefulProgressTime
        let floor = hardRecoveryNoProgressFloor(for: snapshot.transportPathKind)
        guard noUsefulProgressDuration >= floor else {
            MirageLogger.client(
                "Frame loss timeout for stream \(streamID) is monitoring without keyframe request " +
                    "(usefulProgressAgeMs=\(Int((noUsefulProgressDuration * 1000).rounded())), " +
                    "floorMs=\(Int((floor * 1000).rounded())), path=\(snapshot.transportPathKind.rawValue))"
            )
            return true
        }

        if let progress = snapshot.latestPendingKeyframeProgress,
           Self.shouldDeferForPendingKeyframeProgress(
               progress,
               now: now,
               targetFPS: decodeSchedulerTargetFPS
           ) {
            logRecoveryDecision(
                .deferKeyframeProgress,
                reason: "frame-loss-timeout-no-progress",
                snapshot: snapshot
            )
            return true
        }

        reassembler.beginKeyframeWait()
        discardQueuedFramesForRecovery()
        MirageLogger.client(
            "Frame loss timeout for stream \(streamID) had no decoded or presented progress beyond recovery floor; " +
                "requesting one recovery keyframe " +
                "(usefulProgressAgeMs=\(Int((noUsefulProgressDuration * 1000).rounded())), " +
                "floorMs=\(Int((floor * 1000).rounded())), path=\(snapshot.transportPathKind.rawValue))"
        )
        await enterKeyframeRecoveryIfNeeded(reason: "frame-loss-timeout-no-progress")
        await requestKeyframeRecoveryIfPossible(reason: .frameLoss)
        return true
    }

    func cancelMemoryBudgetRecoveryTask() {
        memoryBudgetRecoveryTask?.cancel()
        memoryBudgetRecoveryTask = nil
    }

    func requestKeyframeRecoveryIfPossible(reason: RecoveryReason) async {
        _ = await requestKeyframeRecovery(reason: reason)
    }

    func requestKeyframeRecovery(reason: RecoveryReason, bypassRetryGate: Bool = false) async -> Bool {
        let now = currentTime
        let coalesceInterval = Self.keyframeRequestCoalesceInterval(targetFPS: decodeSchedulerTargetFPS)
        if !bypassRetryGate,
           lastRecoveryRequestDispatchTime > 0,
           now - lastRecoveryRequestDispatchTime < coalesceInterval {
            let remainingMs = Int(max(0, coalesceInterval - (now - lastRecoveryRequestDispatchTime)) * 1000)
            MirageLogger.client(
                "Recovery keyframe request coalesced " +
                    "(\(reason.logLabel), \(remainingMs)ms remaining) for stream \(streamID)"
            )
            return false
        }
        trimRecoveryKeyframeDispatchWindow(now: now)
        if recoveryKeyframeDispatchTimes.count >= Self.recoveryKeyframeDispatchLimit {
            MirageLogger.client(
                "Recovery keyframe request suppressed after \(recoveryKeyframeDispatchTimes.count) requests/" +
                    "\(Int(Self.recoveryKeyframeDispatchWindow))s for stream \(streamID); signaling adaptation pressure"
            )
            if presentationTier == .activeLive {
                let stallHandler = onStallEvent
                await MainActor.run {
                    stallHandler?(.keyframeStarved)
                }
            }
            return false
        }
        let snapshot = reassembler.keyframeWaitSnapshot
        let keyframeDecision = bypassRetryGate
            ? StreamRecoveryDecision.requestKeyframe
            : keyframeRequestDecision(now: now, reason: reason, snapshot: snapshot)
        guard keyframeDecision == .requestKeyframe else {
            logRecoveryDecision(keyframeDecision, reason: reason.logLabel, snapshot: snapshot)
            return false
        }
        let recoveryDecision = recoveryCoordinator.requestAction(
            now: now,
            reason: reason.logLabel,
            targetFPS: decodeSchedulerTargetFPS,
            forceNewEpisode: bypassRetryGate ||
                reason == .manualRecovery ||
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
            recoveryCoordinator.recordDispatchDeferred(until: now + coalesceInterval)
            MirageLogger.client(
                "Recovery keyframe request deferred because no keyframe handler is active " +
                    "(\(reason.logLabel)) for stream \(streamID)"
            )
            return false
        }
        MirageLogger.client("Requesting recovery keyframe (\(reason.logLabel)) for stream \(streamID)")
        if presentationTier == .activeLive,
           clientRecoveryStatus != .postResizeAwaitingFirstFrame,
           clientRecoveryStatus != .hardRecovery {
            await setClientRecoveryStatus(.keyframeRecovery, cause: reason.recoveryCause)
        }
        let didSend = await MainActor.run {
            handler()
        }
        guard didSend else {
            recoveryCoordinator.recordDispatchDeferred(until: now + coalesceInterval)
            MirageLogger.client("Recovery keyframe request not sent by client service for stream \(streamID)")
            return false
        }
        lastRecoveryRequestDispatchTime = now
        recoveryKeyframeDispatchTimes.append(now)
        return true
    }

    private func trimRecoveryKeyframeDispatchWindow(now: CFAbsoluteTime) {
        let oldestAllowed = now - Self.recoveryKeyframeDispatchWindow
        recoveryKeyframeDispatchTimes.removeAll { $0 < oldestAllowed }
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
        await clearKeyframeRecoveryState()
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
            await setClientRecoveryStatus(.keyframeRecovery, cause: reason.recoveryCause)
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
            await enterKeyframeRecoveryIfNeeded(reason: "soft-\(reason.logLabel)", cause: reason.recoveryCause)
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
