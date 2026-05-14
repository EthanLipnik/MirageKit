//
//  StreamContext+KeyframeRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Explicit keyframe recovery requests.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    nonisolated static func shouldScheduleCaptureRestartForRecovery(
        now: CFAbsoluteTime,
        lastCapturedFrameTime: CFAbsoluteTime,
        lastRestartTime: CFAbsoluteTime,
        stallThreshold: CFAbsoluteTime,
        cooldown: CFAbsoluteTime
    )
    -> Bool {
        let safeCooldown = max(0, cooldown)
        if lastRestartTime > 0, now - lastRestartTime < safeCooldown {
            return false
        }

        guard lastCapturedFrameTime > 0 else {
            return true
        }

        let safeThreshold = max(0, stallThreshold)
        let captureGap = max(0, now - lastCapturedFrameTime)
        return captureGap >= safeThreshold
    }

    private func scheduleCaptureRestartForKeyframeRecoveryIfNeeded(
        now: CFAbsoluteTime,
        reason: String
    )
        async {
        guard let captureEngine else { return }
        guard Self.shouldScheduleCaptureRestartForRecovery(
            now: now,
            lastCapturedFrameTime: lastCapturedFrameTime,
            lastRestartTime: lastCaptureStarvationRestartTime,
            stallThreshold: captureStarvationRestartThreshold,
            cooldown: captureStarvationRestartCooldown
        ) else {
            return
        }

        lastCaptureStarvationRestartTime = now
        let thresholdMs = Int((captureStarvationRestartThreshold * 1000).rounded())
        let captureGapMs: String = if lastCapturedFrameTime > 0 {
            String(Int((max(0, now - lastCapturedFrameTime) * 1000).rounded()))
        } else {
            "none"
        }

        await captureEngine.scheduleCaptureRestart(
            reason: "keyframe_recovery_capture_starved reason=\(reason) captureGapMs=\(captureGapMs) thresholdMs=\(thresholdMs)",
            debounce: captureStarvationRestartDebounce
        )
        MirageLogger.stream(
            "Capture restart requested for keyframe recovery (\(reason), captureGapMs=\(captureGapMs), thresholdMs=\(thresholdMs))"
        )
    }

    /// Request a keyframe from the encoder.
    func requestKeyframe() async -> KeyframeRecoveryAckMessage {
        let accepted = await requestKeyframeRecovery()
        return keyframeRecoveryAck(accepted: accepted)
    }

    func requestKeyframeRecoveryIfPossible() async {
        let queued = queueKeyframeRecoveryRequest()
        guard queued else { return }
        await completeAcceptedKeyframeRecoveryRequest(now: CFAbsoluteTimeGetCurrent(), reason: "Keyframe request")
    }

    private func requestKeyframeRecovery() async -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        let reason = "Keyframe request"
        let queued = queueKeyframeRecoveryRequest()
        guard queued else { return false }
        await completeAcceptedKeyframeRecoveryRequest(now: now, reason: reason)
        return true
    }

    private func queueKeyframeRecoveryRequest() -> Bool {
        let reason = "Keyframe request"
        logFreshnessBurstKeyframeRecovery(reason: reason)

        return queueKeyframe(
            reason: reason,
            checkInFlight: true,
            requiresFlush: false,
            requiresReset: false,
            advanceEpochOnReset: false,
            urgent: true
        )
    }

    private func completeAcceptedKeyframeRecoveryRequest(now: CFAbsoluteTime, reason: String) async {
        softRecoveryCount += 1
        noteLossEvent(reason: reason, enablePFrameFEC: true)
        await scheduleCaptureRestartForKeyframeRecoveryIfNeeded(now: now, reason: reason)
        markKeyframeRequestIssued()
        scheduleProcessingIfNeeded()
        MirageLogger
            .stream(
                "Recovery keyframe requests=\(softRecoveryCount)"
            )
    }

    private func keyframeRecoveryAck(accepted: Bool) -> KeyframeRecoveryAckMessage {
        let now = CFAbsoluteTimeGetCurrent()
        let deadlineMs: Int
        let state: KeyframeRecoveryAckState
        if keyframeSendDeadline > now {
            deadlineMs = Int(((keyframeSendDeadline - now) * 1000).rounded(.up))
            state = accepted ? .accepted : .inFlight
        } else {
            deadlineMs = Int((keyframeRequestCooldown * 1000).rounded(.up))
            state = accepted ? .accepted : .cooldown
        }
        return KeyframeRecoveryAckMessage(
            streamID: streamID,
            deadlineMilliseconds: deadlineMs,
            accepted: accepted,
            state: state
        )
    }
}
#endif
