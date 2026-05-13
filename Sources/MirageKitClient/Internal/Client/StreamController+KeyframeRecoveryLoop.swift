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
        if clientRecoveryStatus != .postResizeAwaitingFirstFrame,
           clientRecoveryStatus != .hardRecovery {
            await setClientRecoveryStatus(.keyframeRecovery)
        }
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
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return
                }
            }
        }
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
