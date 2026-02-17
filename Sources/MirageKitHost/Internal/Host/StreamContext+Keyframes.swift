//
//  StreamContext+Keyframes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Keyframe scheduling and motion heuristics.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    func markDiscontinuity(reason: String, advanceEpoch: Bool) {
        if dynamicFrameFlags.contains(.discontinuity) { return }
        if advanceEpoch { epoch &+= 1 }
        dynamicFrameFlags.insert(.discontinuity)
        if advanceEpoch { MirageLogger.stream("Stream epoch advanced to \(epoch) (\(reason))") } else {
            MirageLogger.stream("Stream discontinuity flagged without epoch bump (\(reason))")
        }
    }

    func advanceEpoch(reason: String) {
        markDiscontinuity(reason: reason, advanceEpoch: true)
    }

    func markKeyframeInFlight() {
        let deadline = CFAbsoluteTimeGetCurrent() + keyframeInFlightCap
        if deadline > keyframeSendDeadline { keyframeSendDeadline = deadline }
    }

    func markKeyframeRequestIssued() {
        let deadline = CFAbsoluteTimeGetCurrent() + keyframeInFlightCap
        if deadline > keyframeSendDeadline { keyframeSendDeadline = deadline }
    }

    func shouldThrottleKeyframeRequest(requestLabel: String, checkInFlight: Bool) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if checkInFlight, now < keyframeSendDeadline {
            let remaining = Int(((keyframeSendDeadline - now) * 1000).rounded())
            MirageLogger.stream("\(requestLabel) skipped (keyframe in flight, \(remaining)ms remaining)")
            return true
        }
        let elapsed = now - lastKeyframeRequestTime
        if elapsed < keyframeRequestCooldown {
            let remaining = Int(((keyframeRequestCooldown - elapsed) * 1000).rounded())
            MirageLogger.stream("\(requestLabel) skipped (cooldown \(remaining)ms)")
            return true
        }
        lastKeyframeRequestTime = now
        return false
    }

    @discardableResult
    func queueKeyframe(
        reason: String,
        checkInFlight: Bool,
        requiresFlush: Bool = false,
        requiresReset: Bool = false,
        advanceEpochOnReset: Bool = true,
        urgent: Bool = false
    )
    -> Bool {
        guard !shouldThrottleKeyframeRequest(requestLabel: reason, checkInFlight: checkInFlight) else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        pendingKeyframeReason = reason
        if urgent {
            pendingKeyframeDeadline = now
            pendingKeyframeUrgent = true
        } else {
            pendingKeyframeDeadline = max(pendingKeyframeDeadline, now + keyframeSettleTimeout)
        }
        if requiresReset {
            markDiscontinuity(reason: reason, advanceEpoch: advanceEpochOnReset)
            pendingKeyframeRequiresReset = true
            pendingKeyframeRequiresFlush = true
        }
        if requiresFlush { pendingKeyframeRequiresFlush = true }
        return true
    }

    func forceKeyframeAfterFallbackResume() {
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0
        let queued = queueKeyframe(
            reason: "Fallback resume keyframe",
            checkInFlight: false,
            requiresFlush: false,
            requiresReset: false,
            urgent: true
        )
        if !queued { MirageLogger.stream("Fallback resume keyframe skipped (unable to queue)") }
    }

    func forceKeyframeAfterCaptureRestart(
        restartStreak: Int,
        shouldEscalateRecovery: Bool
    ) {
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0
        let reason = "Capture restart (streak \(restartStreak))"
        noteLossEvent(reason: reason, enablePFrameFEC: true)
        let queued = queueKeyframe(
            reason: "Fallback keyframe",
            checkInFlight: false,
            requiresFlush: true,
            requiresReset: shouldEscalateRecovery,
            urgent: true
        )
        if shouldEscalateRecovery {
            MirageLogger.stream("Capture restart escalation active (streak \(restartStreak))")
        }
        if !queued { MirageLogger.stream("Fallback keyframe skipped (unable to queue after restart)") }
    }

    func shouldEmitPendingKeyframe(queueBytes: Int) -> Bool {
        guard pendingKeyframeReason != nil else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        if pendingKeyframeUrgent {
            pendingKeyframeReason = nil
            pendingKeyframeDeadline = 0
            pendingKeyframeUrgent = false
            lastKeyframeTime = now
            return true
        }
        let settleThreshold = max(minQueuedBytes, Int(Double(queuePressureBytes) * keyframeQueueSettleFactor))
        let settled = queueBytes <= settleThreshold && inFlightCount == 0
        let highMotion = smoothedDirtyPercentage >= keyframeMotionThreshold
        if (settled && !highMotion) || now >= pendingKeyframeDeadline {
            pendingKeyframeReason = nil
            pendingKeyframeDeadline = 0
            lastKeyframeTime = now
            return true
        }
        return false
    }

    static func keyframeCadence(
        intervalFrames: Int,
        frameRate: Int
    )
    -> (interval: CFAbsoluteTime, maxInterval: CFAbsoluteTime) {
        let clampedFrames = max(1, intervalFrames)
        let clampedRate = max(1, frameRate)
        let intervalSeconds = Double(clampedFrames) / Double(clampedRate)
        let cadence = max(1.0, intervalSeconds)
        let maxCadence = max(cadence * 2.0, cadence + 1.0)
        return (cadence, maxCadence)
    }

    func updateKeyframeCadence() {
        let cadence = Self.keyframeCadence(
            intervalFrames: encoderConfig.keyFrameInterval,
            frameRate: currentFrameRate
        )
        keyframeIntervalSeconds = cadence.interval
        keyframeMaxIntervalSeconds = cadence.maxInterval
    }

    func updateMotionState(with frameInfo: CapturedFrameInfo) {
        let normalized = max(0.0, min(1.0, Double(frameInfo.dirtyPercentage) / 100.0))
        if smoothedDirtyPercentage == 0 { smoothedDirtyPercentage = normalized } else {
            smoothedDirtyPercentage = smoothedDirtyPercentage * (1.0 - motionSmoothingFactor)
                + normalized * motionSmoothingFactor
        }
    }

    func shouldQueueScheduledKeyframe(queueBytes: Int) -> Bool {
        guard !recoveryOnlyKeyframes else { return false }
        guard shouldEncodeFrames else { return false }
        guard !isResizing else { return false }
        guard lastKeyframeTime > 0 else { return false }
        guard pendingKeyframeReason == nil else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastKeyframeTime
        guard elapsed >= keyframeIntervalSeconds else { return false }

        let highMotion = smoothedDirtyPercentage >= keyframeMotionThreshold
        let queueBackedUp = queueBytes >= queuePressureBytes
        let allowDespitePressure = elapsed >= keyframeMaxIntervalSeconds

        if highMotion || queueBackedUp, !allowDespitePressure { return false }

        return !shouldThrottleKeyframeRequest(requestLabel: "Scheduled keyframe", checkInFlight: true)
    }

    func markKeyframeSent() {
        lastKeyframeTime = CFAbsoluteTimeGetCurrent()
        pendingKeyframeReason = nil
        pendingKeyframeDeadline = 0
        pendingKeyframeRequiresFlush = false
        pendingKeyframeUrgent = false
        pendingKeyframeRequiresReset = false
        if dynamicFrameFlags.contains(.discontinuity) { dynamicFrameFlags.remove(.discontinuity) }
    }

    func noteLossEvent(reason: String, enablePFrameFEC: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        let lossDeadline = now + lossModeHold
        if lossDeadline > lossModeDeadline { lossModeDeadline = lossDeadline }
        if enablePFrameFEC {
            let pFrameDeadline = now + pFrameFECLossModeHold
            if pFrameDeadline > lossModePFrameFECDeadline { lossModePFrameFECDeadline = pFrameDeadline }
        }
        let pFrameFECRemainderMs = Int(max(0, lossModePFrameFECDeadline - now) * 1000)
        let pFrameFECState = pFrameFECRemainderMs > 0 ? "on(\(pFrameFECRemainderMs)ms)" : "off"
        MirageLogger
            .stream(
                "Loss mode extended to \(Int((lossModeDeadline - now) * 1000))ms, pFrameFEC=\(pFrameFECState) (\(reason))"
            )
    }

    nonisolated func isLossModeActive(now: CFAbsoluteTime) -> Bool {
        now < lossModeDeadline
    }

    nonisolated func isPFrameFECActive(now: CFAbsoluteTime) -> Bool {
        now < lossModePFrameFECDeadline
    }

    nonisolated func resolvedFECBlockSize(isKeyframe: Bool, now: CFAbsoluteTime) -> Int {
        guard isLossModeActive(now: now) else { return 0 }
        if isKeyframe { return 8 }
        return isPFrameFECActive(now: now) ? 16 : 0
    }

    private func resetRecoveryWindowIfNeeded(now: CFAbsoluteTime) {
        if recoveryWindowStart == 0 || now - recoveryWindowStart > softRecoveryWindow {
            recoveryWindowStart = now
            recoveryRequestCount = 0
        }
    }

    /// Request a keyframe from the encoder.
    func requestKeyframe() async {
        let now = CFAbsoluteTimeGetCurrent()
        resetRecoveryWindowIfNeeded(now: now)

        let nextCount = recoveryRequestCount + 1
        let useHardRecovery = nextCount >= hardRecoveryThreshold
        let reason = useHardRecovery ? "Keyframe request (hard)" : "Keyframe request (soft)"

        let queued = queueKeyframe(
            reason: reason,
            checkInFlight: true,
            requiresFlush: useHardRecovery,
            requiresReset: useHardRecovery,
            advanceEpochOnReset: useHardRecovery,
            urgent: true
        )
        guard queued else { return }

        recoveryRequestCount = nextCount
        if useHardRecovery {
            hardRecoveryCount += 1
            noteLossEvent(reason: reason, enablePFrameFEC: true)
        } else {
            softRecoveryCount += 1
            noteLossEvent(reason: reason, enablePFrameFEC: true)
        }
        markKeyframeRequestIssued()
        scheduleProcessingIfNeeded()
        MirageLogger
            .stream(
                "Recovery request=\(recoveryRequestCount) window=\(Int(softRecoveryWindow))s " +
                    "soft=\(softRecoveryCount) hard=\(hardRecoveryCount)"
            )
    }

    /// Force an immediate keyframe by flushing the encoder pipeline.
    func forceImmediateKeyframe() async {
        if shouldThrottleKeyframeRequest(requestLabel: "Immediate keyframe", checkInFlight: false) { return }

        markKeyframeRequestIssued()
        advanceEpoch(reason: "Immediate keyframe")

        await packetSender?.resetQueue(reason: "immediate keyframe")
        await encoder?.flush()
        MirageLogger.stream("Forced immediate keyframe for stream \(streamID)")
    }

    func keyframeQuality(for queueBytes: Int) -> Float {
        _ = queueBytes
        return min(activeQuality, min(encoderConfig.keyframeQuality, compressionQualityCeiling))
    }
}
#endif
