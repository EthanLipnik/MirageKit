//
//  StreamController+FirstFrameMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  First-frame presentation watchdog and bootstrap recovery.
//

import Foundation
import MirageKit

extension StreamController {
    func syncPresentationProgressFromFrameStore(now: CFAbsoluteTime? = nil) -> Bool {
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        let referenceNow = now ?? currentTime

        if snapshot.sequence > lastPresentedSequenceObserved {
            lastPresentedSequenceObserved = snapshot.sequence
            lastPresentedProgressTime = snapshot.submittedTime > 0 ? snapshot.submittedTime : referenceNow
            presentationProgressRequiresSequenceAdvance = false
            clearFreezeRecoveryEpisode(reason: "presentation-progress")
            return true
        }

        if lastPresentedProgressTime == 0 {
            if snapshot.submittedTime > 0 {
                lastPresentedSequenceObserved = max(lastPresentedSequenceObserved, snapshot.sequence)
                lastPresentedProgressTime = snapshot.submittedTime
                presentationProgressRequiresSequenceAdvance = false
                clearFreezeRecoveryEpisode(reason: "presentation-progress")
                return true
            }

            if hasPresentedFirstFrame, !presentationProgressRequiresSequenceAdvance {
                lastPresentedProgressTime = referenceNow
                clearFreezeRecoveryEpisode(reason: "presentation-progress")
                return true
            }
        }

        return false
    }

    func armFirstPresentedFrameAwaiter(
        reason: String,
        mode: FirstPresentedFrameAwaitMode = .startup
    ) async {
        guard !hasTriggeredTerminalStartupFailure else { return }
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        awaitingFirstPresentedFrame = true
        firstPresentedFrameAwaitMode = mode
        firstPresentedFrameBaselineSequence = snapshot.sequence
        firstPresentedFrameWaitReason = reason
        firstPresentedFrameWaitStartTime = currentTime
        firstPresentedFrameLastWaitLogTime = firstPresentedFrameWaitStartTime
        firstPresentedFrameLastRecoveryRequestTime = 0
        firstPresentedFrameRecoveryAttemptCount = 0
        firstPresentedFrameRendererRecoveryAttemptCount = 0
        reassembler.setStartupKeyframeTimeoutOverrideEnabled(true)
        if reason != "post-resize", mode == .startup {
            await setClientRecoveryStatus(.startup, cause: .startupTimeout)
        }

        MirageLogger
            .client(
                "Waiting for first presented frame (\(reason)) for stream \(streamID), baseline sequence \(snapshot.sequence)"
            )
        startFirstPresentedFrameMonitorIfNeeded()
    }

    func stopFirstPresentedFrameMonitor() {
        firstPresentedFrameTask?.cancel()
        firstPresentedFrameTask = nil
        awaitingFirstPresentedFrame = false
        firstPresentedFrameAwaitMode = .startup
        firstPresentedFrameBaselineSequence = 0
        firstPresentedFrameWaitReason = nil
        firstPresentedFrameWaitStartTime = 0
        firstPresentedFrameLastWaitLogTime = 0
        firstPresentedFrameLastRecoveryRequestTime = 0
        firstPresentedFrameRecoveryAttemptCount = 0
        firstPresentedFrameRendererRecoveryAttemptCount = 0
        reassembler.setStartupKeyframeTimeoutOverrideEnabled(false)
    }

    func markFirstFrameDecoded() async {
        let shouldNotify = !hasDecodedFirstFrame
        if !hasDecodedFirstFrame {
            hasDecodedFirstFrame = true
        }

        if awaitingFirstFrameAfterResize {
            MirageLogger.client("Post-resize first frame decoded for stream \(streamID)")
        }

        guard shouldNotify, let handler = onFirstFrameDecoded else { return }
        await MainActor.run {
            handler()
        }
    }

    func markFirstFramePresented() async {
        let now = currentTime
        let wasAwaitingFirstPresentation = awaitingFirstPresentedFrame
        let waitStart = firstPresentedFrameWaitStartTime

        awaitingFirstPresentedFrame = false
        firstPresentedFrameBaselineSequence = 0
        firstPresentedFrameWaitStartTime = 0
        firstPresentedFrameLastWaitLogTime = 0
        firstPresentedFrameLastRecoveryRequestTime = 0
        firstPresentedFrameRecoveryAttemptCount = 0
        firstPresentedFrameRendererRecoveryAttemptCount = 0
        resetTerminalStartupFailureTracking()
        reassembler.setStartupKeyframeTimeoutOverrideEnabled(false)

        if awaitingFirstFrameAfterResize {
            awaitingFirstPresentedFrameAfterResize = false
            if waitStart > 0 {
                let elapsedMs = Int((now - waitStart) * 1000)
                MirageLogger.client(
                    "Post-resize first frame presented for stream \(streamID) (+\(elapsedMs)ms)"
                )
            } else {
                MirageLogger.client("Post-resize first frame presented for stream \(streamID)")
            }
        }

        let shouldNotify = !hasPresentedFirstFrame || wasAwaitingFirstPresentation
        if !hasPresentedFirstFrame {
            hasPresentedFirstFrame = true
        }
        presentationProgressRequiresSequenceAdvance = false
        if !hasDecodedFirstFrame {
            hasDecodedFirstFrame = true
        }
        _ = syncPresentationProgressFromFrameStore(now: now)
        if awaitingFirstFrameAfterResize {
            await maybeCompletePostResizeRecovery()
        } else {
            await setClientRecoveryStatus(.idle)
        }
        guard shouldNotify, let handler = onFirstFramePresented else { return }
        await MainActor.run {
            handler()
        }
    }

    private func startFirstPresentedFrameMonitorIfNeeded() {
        guard firstPresentedFrameTask == nil else { return }
        firstPresentedFrameTask = Task { [weak self] in
            guard let self else { return }
            await runFirstPresentedFrameMonitor()
        }
    }

    private func runFirstPresentedFrameMonitor() async {
        defer { firstPresentedFrameTask = nil }

        while !Task.isCancelled {
            guard awaitingFirstPresentedFrame else { return }

            let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
            if snapshot.sequence > firstPresentedFrameBaselineSequence {
                await markFirstFramePresented()
                return
            }

            let now = currentTime
            maybeLogFirstPresentedFrameWait(now: now, latestSequence: snapshot.sequence)
            await maybeTriggerBootstrapFirstFrameRecovery(now: now, latestSequence: snapshot.sequence)

            do {
                try await Task.sleep(for: Self.firstPresentedFramePollInterval)
            } catch {
                return
            }
        }
    }

    private func maybeLogFirstPresentedFrameWait(now: CFAbsoluteTime, latestSequence: UInt64) {
        guard awaitingFirstPresentedFrame else { return }
        guard firstPresentedFrameWaitStartTime > 0 else { return }
        guard now - firstPresentedFrameLastWaitLogTime >= Self.firstPresentedFrameWaitLogInterval else { return }

        firstPresentedFrameLastWaitLogTime = now
        let elapsedMs = Int((now - firstPresentedFrameWaitStartTime) * 1000)
        let pendingDepth = MirageRenderStreamStore.shared.pendingFrameCount(for: streamID)
        let awaitingKeyframe = reassembler.isAwaitingKeyframe
        let reason = firstPresentedFrameWaitReason ?? "unknown"
        MirageLogger
            .client(
                "Still waiting for first presented frame (\(reason)) for stream \(streamID) (+\(elapsedMs)ms, " +
                    "baseline=\(firstPresentedFrameBaselineSequence), latest=\(latestSequence), " +
                    "pendingFrames=\(pendingDepth), awaitingKeyframe=\(awaitingKeyframe))"
            )
    }

    private func maybeTriggerBootstrapFirstFrameRecovery(
        now: CFAbsoluteTime,
        latestSequence: UInt64
    ) async {
        guard awaitingFirstPresentedFrame,
              firstPresentedFrameWaitStartTime > 0 else { return }
        let elapsed = now - firstPresentedFrameWaitStartTime
        let recoveryGrace = Self.firstPresentedFrameBootstrapRecoveryGrace(for: firstPresentedFrameAwaitMode)
        let hardRecoveryGrace = Self.firstPresentedFrameHardRecoveryGrace(for: firstPresentedFrameAwaitMode)
        guard elapsed >= recoveryGrace else { return }
        guard firstPresentedFrameLastRecoveryRequestTime == 0
            || now - firstPresentedFrameLastRecoveryRequestTime >= Self.firstPresentedFrameRecoveryCooldown else { return }
        if firstPresentedFrameRecoveryAttemptCount > 0,
           elapsed < hardRecoveryGrace {
            return
        }

        let pendingKeyframeProgress = reassembler.latestPendingKeyframeProgress
        if let pendingKeyframeProgress,
           Self.shouldDeferForPendingKeyframeProgress(
               pendingKeyframeProgress,
               now: now,
               targetFPS: decodeSchedulerTargetFPS
           ) {
            return
        }

        let pendingFrameCount = MirageRenderStreamStore.shared.pendingFrameCount(for: streamID)
        if Self.shouldAttemptRendererRecoveryBeforeBootstrapReset(
            pendingFrameCount: pendingFrameCount,
            submittedSequence: latestSequence,
            baselineSequence: firstPresentedFrameBaselineSequence,
            rendererRecoveryAttempts: firstPresentedFrameRendererRecoveryAttemptCount
        ) {
            firstPresentedFrameRendererRecoveryAttemptCount &+= 1
            let didRequestPresenterRecovery = MirageRenderStreamStore.shared.requestPresentationRecovery(for: streamID)
            if didRequestPresenterRecovery {
                firstPresentedFrameLastRecoveryRequestTime = now
                MirageLogger.client(
                    "Startup first-frame presenter recovery requested for stream \(streamID) " +
                        "(pendingFrames=\(pendingFrameCount), submitted=0)"
                )
                return
            }
            MirageLogger.client(
                "Startup first-frame presenter recovery had no active handler for stream \(streamID) " +
                    "(pendingFrames=\(pendingFrameCount), submitted=0)"
            )
            let droppedPendingFrames = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
            if droppedPendingFrames > 0 {
                MirageLogger.client(
                    "Dropped \(droppedPendingFrames) stale pending render frame(s) before startup keyframe " +
                        "recovery for stream \(streamID)"
                )
            }
        }

        let hasPackets = reassembler.hasReceivedPackets
        let awaitingKeyframe = reassembler.isAwaitingKeyframe
        let startupStallKind = if awaitingKeyframe {
            "reassembler awaiting keyframe"
        } else if !hasPackets {
            "no startup packets received"
        } else if latestSequence <= firstPresentedFrameBaselineSequence {
            "no presented frame progress"
        } else {
            "startup presentation stalled"
        }

        firstPresentedFrameLastRecoveryRequestTime = now
        firstPresentedFrameRecoveryAttemptCount &+= 1

        let recoveryAction = Self.bootstrapFirstFrameRecoveryAction(
            hasPackets: hasPackets,
            latestSequence: latestSequence,
            baselineSequence: firstPresentedFrameBaselineSequence
        )

        let shouldEscalateToHardRecovery = elapsed >= hardRecoveryGrace &&
            (firstPresentedFrameRecoveryAttemptCount >= Self.firstPresentedFrameHardRecoveryThreshold ||
                recoveryAction == .hardRecovery)
        if shouldEscalateToHardRecovery {
            MirageLogger.client(
                "Bootstrap first frame recovery escalating to hard reset for stream \(streamID) "
                    + "(waited \(Int(elapsed * 1000))ms, \(startupStallKind))"
            )
            await requestRecovery(
                reason: .startupKeyframeTimeout,
                restartRecoveryLoop: false,
                awaitFirstPresentedFrame: true,
                firstPresentedFrameWaitReason: "startup-hard-recovery"
            )
            return
        }

        MirageLogger.client(
            "Bootstrap first frame recovery: requesting keyframe for stream \(streamID) "
                + "(waited \(Int(elapsed * 1000))ms, \(startupStallKind), transport=healthy-packet-flow)"
        )
        await requestKeyframeRecoveryIfPossible(reason: .startupKeyframeTimeout)
    }
}
