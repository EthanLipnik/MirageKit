//
//  StreamContext+Keyframes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Keyframe scheduling and motion heuristics.
//

import Foundation

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

    func forceKeyframeAfterCaptureRestart() {
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0
        noteLossEvent(reason: "Capture restart")
        let queued = queueKeyframe(
            reason: "Fallback keyframe",
            checkInFlight: false,
            requiresFlush: true,
            requiresReset: true,
            urgent: true
        )
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

    func noteLossEvent(reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let deadline = now + lossModeHold
        if deadline > lossModeDeadline { lossModeDeadline = deadline }
        MirageLogger.stream("Loss mode extended to \(Int((lossModeDeadline - now) * 1000))ms (\(reason))")
    }

    nonisolated func isLossModeActive(now: CFAbsoluteTime) -> Bool {
        now < lossModeDeadline
    }

    /// Request a keyframe from the encoder.
    func requestKeyframe() async {
        if queueKeyframe(
            reason: "Keyframe request",
            checkInFlight: true,
            requiresFlush: true,
            requiresReset: true,
            advanceEpochOnReset: false,
            urgent: true
        ) {
            noteLossEvent(reason: "Keyframe request")
            markKeyframeRequestIssued()
            scheduleProcessingIfNeeded()
        }
    }

    /// Force an immediate keyframe by flushing the encoder pipeline.
    func forceImmediateKeyframe() async {
        if shouldThrottleKeyframeRequest(requestLabel: "Immediate keyframe", checkInFlight: false) { return }

        markKeyframeRequestIssued()

        await packetSender?.resetQueue(reason: "immediate keyframe")
        await encoder?.flush()
        MirageLogger.stream("Forced immediate keyframe for stream \(streamID)")
    }

    func keyframeQuality(for queueBytes: Int) -> Float {
        _ = queueBytes
        return min(activeQuality, encoderConfig.keyframeQuality)
    }
}
#endif
