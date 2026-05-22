//
//  FrameReassembler+Completion.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

extension FrameReassembler {
    func completeFrameLocked(frameNumber: UInt32, frame: PendingFrame) -> FrameCompletionResult {
        // Frame skipping logic: determine if we should deliver this frame
        let shouldDeliver: Bool
        var retainedForInOrderDelivery = false

        if frame.isKeyframe {
            // Always deliver keyframes unless a newer keyframe was already delivered.
            shouldDeliver = !hasDeliveredKeyframeAnchor || isFrameNewer(frameNumber, than: lastDeliveredKeyframe)
            if shouldDeliver {
                lastDeliveredKeyframe = frameNumber
                hasDeliveredKeyframeAnchor = true
            }
        } else {
            // For P-frames: require a delivered keyframe anchor and strict frame monotonicity.
            // If a forward gap is detected, enter keyframe wait and recover from the next keyframe.
            guard hasDeliveredKeyframeAnchor else {
                shouldDeliver = false
                pendingFrames.removeValue(forKey: frameNumber)
                frame.buffer.release()
                droppedFrameCount += 1
                return FrameCompletionResult(
                    frame: nil,
                    frameLossReason: nil,
                    retainedForInOrderDelivery: false
                )
            }
            let expectedNextFrame = lastCompletedFrame &+ 1
            let isForwardFrame = isFrameNewer(frameNumber, than: lastCompletedFrame)
            let isAfterKeyframeAnchor = isFrameNewer(frameNumber, than: lastDeliveredKeyframe)
            let hasForwardGap = isForwardFrame && isFrameNewer(frameNumber, than: expectedNextFrame)

            if hasForwardGap {
                let gapFrames = frameNumber &- expectedNextFrame
                let now = Date()
                if pendingKeyframeContaminatesGapLocked(
                    expectedFrameNumber: expectedNextFrame,
                    now: now
                ) {
                    MirageLogger.log(
                        .frameAssembly,
                        "Holding dependent P-frame behind pending keyframe: expected=\(expectedNextFrame) received=\(frameNumber) gapFrames=\(gapFrames)"
                    )
                    return FrameCompletionResult(
                        frame: nil,
                        frameLossReason: nil,
                        retainedForInOrderDelivery: true
                    )
                }
                let severeForwardGapFrameThreshold = severeForwardGapFrameThresholdLocked()
                if gapFrames >= severeForwardGapFrameThreshold {
                    let severeGapAge = bufferedForwardGapAgeLocked(
                        expectedFrameNumber: expectedNextFrame,
                        currentFrameNumber: frameNumber,
                        currentFrame: frame,
                        now: now
                    )
                    let severeGapGrace = severeForwardGapGraceLocked()
                    if severeGapAge >= severeGapGrace {
                        beginKeyframeWaitLocked()
                        hasSignaledGapFrameLoss = true
                        MirageLogger.log(
                            .frameAssembly,
                            "Severe forward gap detected: expected=\(expectedNextFrame) received=\(frameNumber) " +
                                "gapFrames=\(gapFrames), threshold=\(severeForwardGapFrameThreshold), " +
                                "ageMs=\(Int((severeGapAge * 1000).rounded())), " +
                                "graceMs=\(Int((severeGapGrace * 1000).rounded())); entering keyframe wait"
                        )
                        return FrameCompletionResult(
                            frame: nil,
                            frameLossReason: .severeForwardGap,
                            retainedForInOrderDelivery: false
                        )
                    }
                    MirageLogger.log(
                        .frameAssembly,
                        "severe_forward_gap_buffered expected=\(expectedNextFrame) received=\(frameNumber) " +
                            "gapFrames=\(gapFrames), threshold=\(severeForwardGapFrameThreshold), " +
                            "ageMs=\(Int((severeGapAge * 1000).rounded())), " +
                            "graceMs=\(Int((severeGapGrace * 1000).rounded()))"
                    )
                } else {
                    MirageLogger.log(
                        .frameAssembly,
                        "gap_buffered_for_ordering expected=\(expectedNextFrame) received=\(frameNumber) gapFrames=\(gapFrames)"
                    )
                }
                shouldDeliver = false
                retainedForInOrderDelivery = true
            } else {
                shouldDeliver = isForwardFrame && isAfterKeyframeAnchor
            }
        }

        if shouldDeliver {
            // Discard any pending frames older than this one
            discardOlderPendingFramesLocked(olderThan: frameNumber)
            purgeStaleKeyframesLocked()

            lastCompletedFrame = frameNumber
            hasSignaledGapFrameLoss = false
            pendingFrames.removeValue(forKey: frameNumber)

            if frame.isKeyframe {
                MirageLogger.log(
                    .frameAssembly,
                    "Delivering keyframe \(frameNumber) (\(frame.expectedTotalBytes) bytes)"
                )
                MirageLogger.client(
                    "Keyframe assembled: frame=\(frameNumber), size=\(frame.expectedTotalBytes), stream=\(streamID)"
                )
                clearAwaitingKeyframe()
            }
            let output = frame.buffer.finalize(length: frame.expectedTotalBytes)

            if !frame.isKeyframe {
                recordPFrameCompletionLatencyLocked(frame: frame, now: Date())
                MirageFrameIntegrityDiagnostics.shared.recordPFrame(
                    source: .reassembledPFrame,
                    streamID: streamID,
                    frameNumber: frameNumber,
                    frameBytes: output,
                    expectedBytes: frame.expectedTotalBytes
                )
            }

            let buffer = frame.buffer
            let releaseBuffer: @Sendable () -> Void = { buffer.release() }
            return FrameCompletionResult(
                frame: CompletedFrame(
                    data: output,
                    isKeyframe: frame.isKeyframe,
                    frameNumber: frameNumber,
                    timestamp: frame.timestamp,
                    epoch: frame.epoch,
                    dimensionToken: frame.dimensionToken,
                    contentRect: frame.contentRect,
                    releaseBuffer: releaseBuffer
                ),
                frameLossReason: nil,
                retainedForInOrderDelivery: false
            )
        } else {
            if retainedForInOrderDelivery {
                return FrameCompletionResult(
                    frame: nil,
                    frameLossReason: nil,
                    retainedForInOrderDelivery: true
                )
            }

            // This frame arrived too late - a newer frame was already delivered
            if frame.isKeyframe {
                MirageLogger.log(
                    .frameAssembly,
                    "WARNING: Keyframe \(frameNumber) NOT delivered (lastDeliveredKeyframe=\(lastDeliveredKeyframe))"
                )
            }
            pendingFrames.removeValue(forKey: frameNumber)
            frame.buffer.release()
            droppedFrameCount += 1
            return FrameCompletionResult(
                frame: nil,
                frameLossReason: nil,
                retainedForInOrderDelivery: false
            )
        }
    }

    func drainDeliverableFramesLocked() -> DrainCompletionResult {
        var drainedFrames: [CompletedFrame] = []
        var frameLossReason: FrameLossReason?

        while hasDeliveredKeyframeAnchor {
            let expectedFrameNumber = lastCompletedFrame &+ 1
            guard let expectedFrame = pendingFrames[expectedFrameNumber], expectedFrame.isComplete else { break }

            let completionResult = completeFrameLocked(
                frameNumber: expectedFrameNumber,
                frame: expectedFrame
            )
            if let completedFrame = completionResult.frame {
                drainedFrames.append(completedFrame)
            }
            if let completionLossReason = completionResult.frameLossReason {
                frameLossReason = completionLossReason
            }
            if completionResult.retainedForInOrderDelivery {
                break
            }
        }

        return DrainCompletionResult(
            frames: drainedFrames,
            frameLossReason: frameLossReason
        )
    }

    private func discardOlderPendingFramesLocked(olderThan frameNumber: UInt32) {
        let framesToDiscard = pendingFrames.keys.filter { pendingFrameNumber in
            // Discard P-frames older than the one we're about to deliver
            // Handle wrap-around: if difference is huge, it's probably wrap-around
            guard pendingFrameNumber < frameNumber, frameNumber - pendingFrameNumber < 1000 else { return false }
            // NEVER discard pending keyframes - they're critical for decoder recovery
            // Keyframes are large (500+ packets) and take longer to arrive than P-frames
            // If we discard an incomplete keyframe, the decoder will be stuck
            if let frame = pendingFrames[pendingFrameNumber], frame.isKeyframe { return false }
            return true
        }

        for discardFrame in framesToDiscard {
            if let frame = pendingFrames[discardFrame] {
                droppedFrameCount += 1
                frame.buffer.release()
                pendingFrames.removeValue(forKey: discardFrame)
            }
        }
    }

    func resetForEpoch(_ epoch: UInt16, reason: String) {
        currentEpoch = epoch
        for frame in pendingFrames.values {
            frame.buffer.release()
        }
        pendingFrames.removeAll()
        lastCompletedFrame = 0
        lastDeliveredKeyframe = 0
        hasDeliveredKeyframeAnchor = false
        hasSignaledGapFrameLoss = false
        clearAwaitingKeyframe()
        beginAwaitingKeyframe()
        MirageLogger.log(.frameAssembly, "Epoch \(epoch) reset (\(reason)) for stream \(streamID)")
    }

    func isEpochNewer(_ incoming: UInt16, than current: UInt16) -> Bool {
        let diff = UInt16(incoming &- current)
        // Treat epochs as monotonically increasing with wrap-around semantics.
        // Values in the "forward" half-range are considered newer.
        return diff != 0 && diff < 0x8000
    }

    func isFrameNewer(_ incoming: UInt32, than current: UInt32) -> Bool {
        let diff = incoming &- current
        return diff != 0 && diff < 0x8000_0000
    }

    func cleanupOldFramesLocked() -> TimeoutCleanupResult {
        let now = Date()
        let pFrameNoProgressTimeout = pFrameTimeoutLocked()
        let pFrameAbsoluteLifetimeCap = pFrameAbsoluteLifetimeCapLocked()
        let bufferedForwardGapTimeout = bufferedForwardGapTimeoutLocked()

        var timedOutPFrameCount: UInt64 = 0
        var timedOutKeyframeCount: UInt64 = 0
        var staleKeyframeCount: UInt64 = 0
        var incompleteFrameTimeouts: UInt64 = 0
        var incompleteFrameNoProgressTimeouts: UInt64 = 0
        var incompleteFrameLifetimeTimeouts: UInt64 = 0
        var missingFragmentTimeouts: UInt64 = 0
        var timedOutExpectedPFrame = false
        var framesToRemove: [UInt32] = []
        for (frameNumber, frame) in pendingFrames {
            if frame.isKeyframe, isStaleKeyframeLocked(frameNumber) {
                framesToRemove.append(frameNumber)
                staleKeyframeCount += 1
                continue
            }
            let noProgressTimedOut: Bool
            let lifetimeTimedOut: Bool
            if frame.isKeyframe {
                let timeout = keyframeNoProgressTimeoutLocked(for: frame)
                noProgressTimedOut = now.timeIntervalSince(frame.lastProgressAt) >= timeout
                lifetimeTimedOut = false
            } else {
                noProgressTimedOut = if isRetainedCompleteForwardGapFrameLocked(
                    frameNumber: frameNumber,
                    frame: frame
                ) {
                    false
                } else {
                    now.timeIntervalSince(frame.lastProgressAt) >= pFrameNoProgressTimeout
                }
                lifetimeTimedOut = now.timeIntervalSince(frame.receivedAt) >= pFrameAbsoluteLifetimeCap
            }
            let shouldKeep = !noProgressTimedOut && !lifetimeTimedOut
            if !shouldKeep {
                // Log timeout with fragment completion info for debugging
                let receivedCount = frame.receivedCount
                let totalCount = frame.dataFragmentCount
                let missingDataFragments = max(0, totalCount - min(receivedCount, totalCount))
                let isKeyframe = frame.isKeyframe
                let timeoutCause = lifetimeTimedOut && !noProgressTimedOut ? "lifetime" : "no-progress"
                MirageLogger.log(
                    .frameAssembly,
                    "Frame \(frameNumber) timed out (\(timeoutCause)): " +
                        "\(receivedCount)/\(totalCount) fragments\(isKeyframe ? " (KEYFRAME)" : "")"
                )
                if missingDataFragments > 0, !isKeyframe {
                    incompleteFrameTimeouts += 1
                    if lifetimeTimedOut && !noProgressTimedOut {
                        incompleteFrameLifetimeTimeouts += 1
                    } else {
                        incompleteFrameNoProgressTimeouts += 1
                    }
                    missingFragmentTimeouts += UInt64(missingDataFragments)
                }
                if isKeyframe {
                    timedOutKeyframeCount += 1
                    MirageLogger.client(
                        "Keyframe timed out: frame=\(frameNumber), \(receivedCount)/\(totalCount) fragments, stream=\(streamID)"
                    )
                } else {
                    timedOutPFrameCount += 1
                    let expectedFrame = lastCompletedFrame &+ 1
                    if frameNumber == expectedFrame {
                        timedOutExpectedPFrame = true
                    }
                }
            }
            if !shouldKeep { framesToRemove.append(frameNumber) }
        }
        let missingExpectedPFrameGapTimedOut = hasDeliveredKeyframeAnchor &&
            timedOutExpectedPFrame == false &&
            !pendingKeyframeContaminatesGapLocked(
                expectedFrameNumber: lastCompletedFrame &+ 1,
                now: now
            ) &&
            hasTimedOutBufferedForwardGapLocked(now: now, timeout: bufferedForwardGapTimeout)
        for frameNumber in framesToRemove {
            if let frame = pendingFrames.removeValue(forKey: frameNumber) { frame.buffer.release() }
        }
        droppedFrameCount += timedOutPFrameCount + timedOutKeyframeCount + staleKeyframeCount
        incompleteFrameTimeoutCount += incompleteFrameTimeouts
        incompleteFrameNoProgressTimeoutCount += incompleteFrameNoProgressTimeouts
        incompleteFrameLifetimeTimeoutCount += incompleteFrameLifetimeTimeouts
        missingFragmentTimeoutCount += missingFragmentTimeouts
        if missingExpectedPFrameGapTimedOut {
            forwardGapTimeoutCount += 1
        }

        // Enter keyframe wait when a keyframe times out, or when the next expected P-frame
        // times out, or when a buffered forward gap persists without the expected frame ever arriving.
        let shouldEnterAwaitingKeyframe = (
            timedOutKeyframeCount > 0 ||
                timedOutExpectedPFrame ||
                missingExpectedPFrameGapTimedOut
        ) && !awaitingKeyframe

        if missingExpectedPFrameGapTimedOut {
            let expectedFrame = lastCompletedFrame &+ 1
            if let earliestBufferedFrame = pendingFrames
                .keys
                .filter({ isFrameNewer($0, than: lastCompletedFrame) })
                .min() {
                let gapFrames = earliestBufferedFrame &- expectedFrame
                MirageLogger.log(
                    .frameAssembly,
                    "Forward gap timed out: expected=\(expectedFrame) earliestBuffered=\(earliestBufferedFrame) gapFrames=\(gapFrames)"
                )
            }
        }

        return TimeoutCleanupResult(
            timedOutPFrames: timedOutPFrameCount,
            timedOutKeyframes: timedOutKeyframeCount,
            missingExpectedPFrameGapTimedOut: missingExpectedPFrameGapTimedOut,
            shouldEnterAwaitingKeyframe: shouldEnterAwaitingKeyframe,
            incompleteFrameTimeouts: incompleteFrameTimeouts,
            incompleteFrameNoProgressTimeouts: incompleteFrameNoProgressTimeouts,
            incompleteFrameLifetimeTimeouts: incompleteFrameLifetimeTimeouts,
            missingFragmentTimeouts: missingFragmentTimeouts,
            forwardGapTimeouts: missingExpectedPFrameGapTimedOut ? 1 : 0
        )
    }

    func beginKeyframeWaitLocked() {
        beginAwaitingKeyframe()
        let framesToRelease = pendingFrames.filter { entry in
            let frame = entry.value
            if frame.isKeyframe { return isStaleKeyframeLocked(entry.key) }
            return true
        }
        for frame in framesToRelease.values {
            frame.buffer.release()
        }
        pendingFrames = pendingFrames.filter { entry in
            entry.value.isKeyframe && !isStaleKeyframeLocked(entry.key)
        }
    }

    private func hasTimedOutBufferedForwardGapLocked(
        now: Date,
        timeout: TimeInterval
    ) -> Bool {
        let expectedFrame = lastCompletedFrame &+ 1
        guard pendingFrames[expectedFrame] == nil else { return false }

        guard let earliestBufferedForwardFrame = pendingFrames
            .filter({ isFrameNewer($0.key, than: lastCompletedFrame) })
            .min(by: { lhs, rhs in
                if lhs.key == rhs.key {
                    return lhs.value.receivedAt < rhs.value.receivedAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            }) else {
            return false
        }

        guard isFrameNewer(earliestBufferedForwardFrame.key, than: expectedFrame) else { return false }
        return now.timeIntervalSince(earliestBufferedForwardFrame.value.receivedAt) >= timeout
    }

    private func isRetainedCompleteForwardGapFrameLocked(
        frameNumber: UInt32,
        frame: PendingFrame
    ) -> Bool {
        guard hasDeliveredKeyframeAnchor,
              !frame.isKeyframe,
              frame.isComplete else {
            return false
        }

        let expectedFrame = lastCompletedFrame &+ 1
        guard pendingFrames[expectedFrame] == nil,
              isFrameNewer(frameNumber, than: expectedFrame) else {
            return false
        }

        return true
    }

    private func pendingKeyframeContaminatesGapLocked(
        expectedFrameNumber: UInt32,
        now: Date
    ) -> Bool {
        guard let pendingKeyframe = pendingFrames
            .filter({ entry in
                let frameNumber = entry.key
                let frame = entry.value
                guard frame.isKeyframe, !isStaleKeyframeLocked(frameNumber) else { return false }
                return frameNumber == expectedFrameNumber || isFrameNewer(frameNumber, than: expectedFrameNumber)
            })
            .max(by: { lhs, rhs in
                let lhsProgress = keyframeProgressRatioLocked(lhs.value)
                let rhsProgress = keyframeProgressRatioLocked(rhs.value)
                if lhsProgress != rhsProgress {
                    return lhsProgress < rhsProgress
                }
                if lhs.value.lastProgressAt != rhs.value.lastProgressAt {
                    return lhs.value.lastProgressAt < rhs.value.lastProgressAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            })?
            .value else {
            return false
        }
        guard pendingKeyframe.receivedCount > 0 else { return false }

        let frameInterval = 1.0 / Double(max(1, targetFrameRate))
        let freshProgressWindow = min(0.50, max(0.15, frameInterval * 18.0))
        if now.timeIntervalSince(pendingKeyframe.lastProgressAt) < freshProgressWindow {
            return true
        }

        let progressRatio = keyframeProgressRatioLocked(pendingKeyframe)
        let baseAssemblyWindow = min(3.0, max(0.75, frameInterval * 90.0))
        let progressBonus: TimeInterval
        if progressRatio >= 0.75 {
            progressBonus = 2.0
        } else if progressRatio >= 0.25 {
            progressBonus = 1.0
        } else {
            progressBonus = 0
        }
        return now.timeIntervalSince(pendingKeyframe.receivedAt) < baseAssemblyWindow + progressBonus
    }

    func shouldBufferNonKeyframeWhileAwaitingKeyframeLocked(frameNumber: UInt32) -> Bool {
        _ = frameNumber
        return !awaitingKeyframe
    }

    private func pFrameTimeoutLocked() -> TimeInterval {
        pFrameNoProgressTimeout
    }

    private func pFrameAbsoluteLifetimeCapLocked() -> TimeInterval {
        if latencyMode == .smoothest || transportPathKind == .vpn {
            return pFrameAbsoluteLifetimeCapRemoteSmoothest
        }
        return pFrameAbsoluteLifetimeCapDefault
    }

    private func bufferedForwardGapTimeoutLocked() -> TimeInterval {
        transportPathKind == .vpn ? vpnBufferedForwardGapTimeout : pFrameTimeoutLocked()
    }

    private func keyframeNoProgressTimeoutLocked(for frame: PendingFrame) -> TimeInterval {
        var timeout = startupKeyframeTimeoutOverrideEnabled ? startupKeyframeTimeout : keyframeTimeout
        if transportPathKind == .vpn {
            timeout = max(timeout, vpnKeyframeTimeout)
        }

        let progressRatio = keyframeProgressRatioLocked(frame)
        if progressRatio >= 0.90 {
            timeout += nearCompleteKeyframeTimeoutBonus
        } else if progressRatio >= pendingKeyframeProgressPreservationThreshold {
            timeout += highProgressKeyframeTimeoutBonus
        }
        return timeout
    }

    private func severeForwardGapFrameThresholdLocked() -> UInt32 {
        let frameRate = max(1, targetFrameRate)
        let frameInterval = 1.0 / Double(frameRate)
        let timeout = bufferedForwardGapTimeoutLocked()
        return max(3, UInt32(ceil(timeout / frameInterval)))
    }

    private func severeForwardGapGraceLocked() -> TimeInterval {
        bufferedForwardGapTimeoutLocked()
    }

    private func bufferedForwardGapAgeLocked(
        expectedFrameNumber: UInt32,
        currentFrameNumber: UInt32,
        currentFrame: PendingFrame,
        now: Date
    ) -> TimeInterval {
        let earliestBufferedForwardFrame = pendingFrames
            .filter { entry in
                let frameNumber = entry.key
                return frameNumber == currentFrameNumber ||
                    isFrameNewer(frameNumber, than: expectedFrameNumber)
            }
            .min { lhs, rhs in
                if lhs.key == rhs.key {
                    return lhs.value.receivedAt < rhs.value.receivedAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            }?
            .value ?? currentFrame
        return max(0, now.timeIntervalSince(earliestBufferedForwardFrame.receivedAt))
    }

    func shouldPromotePendingKeyframeLocked(now: Date) -> Bool {
        guard hasDeliveredKeyframeAnchor, !awaitingKeyframe else { return false }

        let expectedFrame = lastCompletedFrame &+ 1
        guard pendingFrames[expectedFrame] == nil else { return false }

        guard let newestPendingKeyframe = pendingFrames
            .filter({ $0.value.isKeyframe && isFrameNewer($0.key, than: expectedFrame) })
            .max(by: { lhs, rhs in
                if lhs.key == rhs.key {
                    return lhs.value.lastProgressAt < rhs.value.lastProgressAt
                }
                return isFrameNewer(rhs.key, than: lhs.key)
            }) else {
            return false
        }

        let elapsed = now.timeIntervalSince(newestPendingKeyframe.value.receivedAt)
        let progressRatio: Double = if newestPendingKeyframe.value.dataFragmentCount > 0 {
            Double(newestPendingKeyframe.value.receivedCount) /
                Double(newestPendingKeyframe.value.dataFragmentCount)
        } else {
            0
        }
        return elapsed >= pendingKeyframePromotionDelay ||
            progressRatio >= pendingKeyframePromotionProgressThreshold
    }

    func promotePendingKeyframeLocked() {
        beginAwaitingKeyframe()
        let preservedKeyframes = pendingFrames.filter(\.value.isKeyframe)
        for frame in pendingFrames.values where !frame.isKeyframe {
            frame.buffer.release()
        }
        pendingFrames = preservedKeyframes
    }

}
