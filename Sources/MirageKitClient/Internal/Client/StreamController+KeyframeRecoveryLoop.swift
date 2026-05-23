//
//  StreamController+KeyframeRecoveryLoop.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

extension StreamController {
    /// Starts the bounded keyframe retry loop for active streams waiting on a keyframe.
    func startKeyframeRecoveryLoopIfNeeded() async {
        guard presentationTier == .activeLive else { return }
        guard keyframeRecoveryTask == nil else { return }
        keyframeRecoveryAttempt = 0
        lastRecoveryRequestTime = 0
        recoveryKeyframeDispatchTimes.removeAll(keepingCapacity: false)
        if clientRecoveryStatus != .postResizeAwaitingFirstFrame,
           clientRecoveryStatus != .hardRecovery {
            await setClientRecoveryStatus(.keyframeRecovery)
        }
        _ = MirageRenderStreamStore.shared.resetPresentation(
            for: streamID,
            dropPendingFrames: true,
            reason: "keyframe-recovery-start"
        )
        keyframeRecoveryTask = Task { [weak self] in
            await self?.runKeyframeRecoveryLoop()
        }
    }

    /// Stops the keyframe retry loop and clears keyframe-recovery state.
    func stopKeyframeRecoveryLoop() async {
        keyframeRecoveryTask?.cancel()
        keyframeRecoveryTask = nil
        keyframeRecoveryAttempt = 0
        lastRecoveryRequestTime = 0
        recoveryKeyframeDispatchTimes.removeAll(keepingCapacity: false)
        recoveryCoordinator.recordProgress()
        if clientRecoveryStatus == .keyframeRecovery {
            await setClientRecoveryStatus(.idle)
        }
    }

    private func runKeyframeRecoveryLoop() async {
        let episodeStartedAt = currentTime
        let episodeDeadline = episodeStartedAt + RecoveryCoordinator.episodeDuration(
            targetFPS: decodeSchedulerTargetFPS
        )
        defer { keyframeRecoveryTask = nil }

        while !Task.isCancelled {
            guard presentationTier == .activeLive else { return }
            guard reassembler.isAwaitingKeyframe else { return }

            let now = currentTime
            if now >= episodeDeadline ||
                keyframeRecoveryAttempt >= Self.activeRecoveryMaxKeyframeAttempts {
                MirageLogger.client(
                    "Keyframe recovery episode ended for stream \(streamID) " +
                        "(attempts=\(keyframeRecoveryAttempt), elapsedMs=\(Int((now - episodeStartedAt) * 1000)))"
                )
                await escalateKeyframeRecoveryAfterExhaustion(
                    episodeStartedAt: episodeStartedAt,
                    now: now
                )
                return
            }

            let retryInterval = Self.keyframeRecoveryRetryDelay(
                attempt: keyframeRecoveryAttempt,
                targetFPS: decodeSchedulerTargetFPS
            )
            let nextRequestTime = lastRecoveryRequestTime > 0
                ? lastRecoveryRequestTime + retryInterval
                : now + retryInterval
            let sleepUntil = min(nextRequestTime, episodeDeadline)
            let sleepSeconds = sleepUntil - now
            if sleepSeconds > 0 {
                do {
                    try await Task.sleep(for: Self.duration(seconds: sleepSeconds))
                } catch {
                    return
                }
                continue
            }

            let didDispatch = await requestKeyframeRecovery(reason: .keyframeRecoveryLoop)
            if didDispatch {
                keyframeRecoveryAttempt &+= 1
            } else {
                let nextDelay = keyframeRecoveryDispatchRetryDelay(now: currentTime)
                do {
                    try await Task.sleep(for: Self.duration(seconds: nextDelay))
                } catch {
                    return
                }
            }
        }
    }

    private func keyframeRecoveryDispatchRetryDelay(now: CFAbsoluteTime) -> CFAbsoluteTime {
        if recoveryCoordinator.retryDeadline > now {
            return max(0.02, min(1.0, recoveryCoordinator.retryDeadline - now))
        }
        guard recoveryKeyframeDispatchTimes.count >= Self.recoveryKeyframeDispatchLimit,
              let oldest = recoveryKeyframeDispatchTimes.first else {
            return 0.02
        }
        let nextWindowTime = oldest + Self.recoveryKeyframeDispatchWindow
        return max(0.02, min(1.0, nextWindowTime - now))
    }

    private func escalateKeyframeRecoveryAfterExhaustion(
        episodeStartedAt: CFAbsoluteTime,
        now: CFAbsoluteTime
    ) async {
        guard hasPresentedFirstFrame,
              presentationTier == .activeLive,
              reassembler.isAwaitingKeyframe,
              clientRecoveryStatus != .hardRecovery else {
            return
        }

        MirageLogger.client(
            "Keyframe recovery exhausted for stream \(streamID); escalating to hard recovery " +
                "(elapsedMs=\(Int((now - episodeStartedAt) * 1000)))"
        )
        await requestRecovery(
            reason: .frameLoss,
            restartRecoveryLoop: false,
            awaitFirstPresentedFrame: true,
            firstPresentedFrameWaitReason: "keyframe-recovery-hard-reset"
        )
    }
}
