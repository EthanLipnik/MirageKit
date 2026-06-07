//
//  MirageVideoPlayoutBuffer.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 5/21/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
import CoreMedia
import Foundation

/// Stateful client playout buffer for decoded video frames.
package struct MirageVideoPlayoutBuffer {
    private var latencyMode: MirageMedia.MirageStreamLatencyMode = .lowestLatency
    private var transportPathKind: MirageCore.MirageNetworkPathKind = .unknown
    private var mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown
    private var baseTargetPlayoutDelayMs: Double = 0
    private var adaptedDelayMs: Double = 0
    private var playbackStarted = false

    private var anchorRemotePresentationTime: CMTime = .invalid
    private var anchorTargetPlayoutTime: CFAbsoluteTime = 0
    private var lastEnqueuedTargetPlayoutTime: CFAbsoluteTime = 0
    private var lastEnqueuedDecodeTime: CFAbsoluteTime = 0
    private var consecutiveBurstFrames = 0
    private var stableWindowStartTime: CFAbsoluteTime = 0
    private var lastInstabilityTime: CFAbsoluteTime = 0
    private var lastDelayIncreaseTime: CFAbsoluteTime = 0

    package init() {}

    package mutating func reset() {
        latencyMode = .lowestLatency
        transportPathKind = .unknown
        mediaPathProfile = .unknown
        baseTargetPlayoutDelayMs = 0
        adaptedDelayMs = 0
        playbackStarted = false
        resetPlayoutAnchors()
        consecutiveBurstFrames = 0
        stableWindowStartTime = 0
        lastInstabilityTime = 0
        lastDelayIncreaseTime = 0
    }

    package mutating func resetPresentationEpoch(policy: MiragePresentationLatencyPolicy, now: CFAbsoluteTime) {
        configureIfNeeded(policy: policy, now: now)
        playbackStarted = false
        resetPlayoutAnchors()
        consecutiveBurstFrames = 0
        stableWindowStartTime = now
        lastInstabilityTime = now
    }

    package mutating func enqueue(
        _ frame: MirageRenderFrame,
        into frames: inout [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> TrimResult {
        configureIfNeeded(policy: policy, now: now)

        if !policy.usesBufferedPlayout {
            frames.append(
                frame.withPlayoutMetadata(
                    transportPathKind: policy.transportPathKind,
                    targetPlayoutTime: nil,
                    targetPlayoutDelayMs: 0
                )
            )
            var result = TrimResult.empty
            while frames.count > policy.maximumQueueDepth {
                frames.removeFirst()
                result.recordLowestLatencyDrop(count: 1)
            }
            return result
        }

        let previousEnqueuedDecodeTime = lastEnqueuedDecodeTime
        let scheduledFrame = frame.withPlayoutMetadata(
            transportPathKind: policy.transportPathKind,
            targetPlayoutTime: targetPlayoutTime(for: frame, policy: policy, now: now),
            targetPlayoutDelayMs: effectiveDelayMs(policy: policy)
        )
        frames.append(scheduledFrame)
        recordBurstPressureIfNeeded(
            frame: scheduledFrame,
            queuedFrameCount: frames.count,
            previousEnqueuedDecodeTime: previousEnqueuedDecodeTime,
            policy: policy,
            now: now
        )
        return trimSmoothestFrames(from: &frames, policy: policy, now: now)
    }

    package mutating func selectFrame(
        frames: inout [MirageRenderFrame],
        after submittedCursor: MirageRenderCursor,
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> Selection {
        configureIfNeeded(policy: policy, now: now)
        var trimResult = removeSubmittedFrames(
            from: &frames,
            after: submittedCursor
        )
        guard !frames.isEmpty else {
            resetPlayoutAnchors()
            return Selection(frame: nil, trimResult: trimResult, selectedFrameNumber: nil)
        }

        if !policy.usesBufferedPlayout {
            let removed = max(0, frames.count - 1)
            if removed > 0 {
                frames.removeFirst(removed)
                trimResult.lateFrameDrops += removed
                trimResult.coalescedFrames += removed
            }
            let frame = frames.first
            return Selection(frame: frame, trimResult: trimResult, selectedFrameNumber: frame?.frameNumber)
        }

        let trim = trimSmoothestFrames(from: &frames, policy: policy, now: now)
        trimResult.absorb(trim)
        guard let frame = frames.first else {
            resetPlayoutAnchors()
            return Selection(frame: nil, trimResult: trimResult, selectedFrameNumber: nil)
        }
        guard frameIsReadyForPlayout(frame, policy: policy, now: now) else {
            if policy.latencyMode == .balanced,
               !policy.usesAwdlRealtimePolicy,
               let recoveryFrame = selectBalancedRecoveryFrame(
                   from: &frames,
                   policy: policy,
                   now: now,
                   trimResult: &trimResult
               ) {
                playbackStarted = true
                noteStableSample(policy: policy, now: now)
                return Selection(
                    frame: recoveryFrame,
                    trimResult: trimResult,
                    selectedFrameNumber: recoveryFrame.frameNumber
                )
            }
            return Selection(frame: nil, trimResult: trimResult, selectedFrameNumber: nil)
        }

        playbackStarted = true
        noteStableSample(policy: policy, now: now)
        return Selection(frame: frame, trimResult: trimResult, selectedFrameNumber: frame.frameNumber)
    }

    package mutating func trimAfterPolicyChange(
        frames: inout [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> TrimResult {
        configureIfNeeded(policy: policy, now: now)
        if !policy.usesBufferedPlayout {
            var result = TrimResult.empty
            while frames.count > policy.maximumQueueDepth {
                frames.removeFirst()
                result.recordLowestLatencyDrop(count: 1)
            }
            return result
        }
        return trimSmoothestFrames(from: &frames, policy: policy, now: now)
    }

    package mutating func recordDisplayTickWithoutFrame(
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) {
        configureIfNeeded(policy: policy, now: now)
        guard policy.usesBufferedPlayout, playbackStarted else { return }
        guard policy.latencyMode != .balanced || policy.usesAwdlRealtimePolicy else {
            resetPlayoutAnchors()
            return
        }
        increaseDelay(
            reason: .underflow,
            amountMs: max(20, policy.displayFrameIntervalMs * 2),
            policy: policy,
            now: now
        )
        resetPlayoutAnchors()
    }

    package mutating func recordFrameArrivedAfterEmptyTick(
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) {
        configureIfNeeded(policy: policy, now: now)
        guard policy.usesBufferedPlayout, playbackStarted else { return }
        guard policy.latencyMode != .balanced || policy.usesAwdlRealtimePolicy else { return }
        increaseDelay(
            reason: .frameAfterEmptyTick,
            amountMs: max(15, policy.displayFrameIntervalMs * 1.5),
            policy: policy,
            now: now
        )
    }

    package func smoothestDisplayDebtMs(
        frames: [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> Double {
        guard policy.usesBufferedPlayout, let first = frames.first else { return 0 }
        let playoutDebtMs = max(0, now - effectiveTargetPlayoutTime(for: first, policy: policy)) * 1000
        let depthDebtMs = Double(max(0, frames.count - 1)) * policy.displayFrameIntervalMs
        return max(playoutDebtMs, depthDebtMs)
    }

    package func smoothestTargetDelayMs(policy: MiragePresentationLatencyPolicy) -> Double {
        guard policy.usesBufferedPlayout else { return 0 }
        return effectiveDelayMs(policy: policy)
    }

    private mutating func configureIfNeeded(
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) {
        let policyBaseTargetPlayoutDelayMs = policy.baseTargetPlayoutDelayMs
        let pathPolicyChanged = latencyMode != policy.latencyMode ||
            transportPathKind != policy.transportPathKind ||
            mediaPathProfile != policy.mediaPathProfile
        let baseTargetChanged = abs(baseTargetPlayoutDelayMs - policyBaseTargetPlayoutDelayMs) > 0.5
        guard pathPolicyChanged || baseTargetChanged else { return }
        let previousBaseTargetPlayoutDelayMs = baseTargetPlayoutDelayMs
        latencyMode = policy.latencyMode
        transportPathKind = policy.transportPathKind
        mediaPathProfile = policy.mediaPathProfile
        baseTargetPlayoutDelayMs = policyBaseTargetPlayoutDelayMs
        if pathPolicyChanged {
            adaptedDelayMs = policyBaseTargetPlayoutDelayMs
        } else if policyBaseTargetPlayoutDelayMs > previousBaseTargetPlayoutDelayMs {
            adaptedDelayMs = max(adaptedDelayMs, policyBaseTargetPlayoutDelayMs)
        } else {
            adaptedDelayMs = min(policy.maximumTargetPlayoutDelayMs, max(policy.minimumTargetPlayoutDelayMs, adaptedDelayMs))
        }
        if pathPolicyChanged || policyBaseTargetPlayoutDelayMs > previousBaseTargetPlayoutDelayMs {
            playbackStarted = false
            resetPlayoutAnchors()
        }
        consecutiveBurstFrames = 0
        stableWindowStartTime = now
        lastInstabilityTime = now
        if pathPolicyChanged {
            lastDelayIncreaseTime = 0
        }
    }

    private mutating func targetPlayoutTime(
        for frame: MirageRenderFrame,
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> CFAbsoluteTime {
        let delaySeconds = effectiveDelayMs(policy: policy) / 1000
        let firstFrameAfterAnchorReset = anchorTargetPlayoutTime <= 0
        if firstFrameAfterAnchorReset {
            let target = max(now, frame.decodeTime) + delaySeconds
            anchorTargetPlayoutTime = target
            anchorRemotePresentationTime = frame.remotePresentationTime
            lastEnqueuedTargetPlayoutTime = target
            lastEnqueuedDecodeTime = frame.decodeTime
            return target
        }

        let target: CFAbsoluteTime
        if frame.remotePresentationTime.isValid,
           anchorRemotePresentationTime.isValid {
            let remoteDelta = CMTimeGetSeconds(CMTimeSubtract(frame.remotePresentationTime, anchorRemotePresentationTime))
            if remoteDelta.isFinite,
               remoteDelta >= 0,
               remoteDelta <= maximumRemoteDeltaSeconds(policy: policy) {
                target = anchorTargetPlayoutTime + remoteDelta
            } else {
                target = lastEnqueuedTargetPlayoutTime + policy.sourceFrameIntervalMs / 1000
            }
        } else {
            target = lastEnqueuedTargetPlayoutTime + policy.sourceFrameIntervalMs / 1000
        }

        let minimumTarget = max(now, frame.decodeTime)
        let resolvedTarget: CFAbsoluteTime
        if target + 0.001 < minimumTarget {
            resolvedTarget = minimumTarget + delaySeconds
            anchorTargetPlayoutTime = resolvedTarget
            anchorRemotePresentationTime = frame.remotePresentationTime
        } else if target > maximumFutureTarget(policy: policy, now: now, decodeTime: frame.decodeTime) {
            resolvedTarget = minimumTarget + delaySeconds
            anchorTargetPlayoutTime = resolvedTarget
            anchorRemotePresentationTime = frame.remotePresentationTime
        } else {
            resolvedTarget = target
        }

        lastEnqueuedTargetPlayoutTime = resolvedTarget
        lastEnqueuedDecodeTime = frame.decodeTime
        return resolvedTarget
    }

    private mutating func trimSmoothestFrames(
        from frames: inout [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> TrimResult {
        var result = TrimResult.empty
        guard !frames.isEmpty else { return result }

        while frames.count > 1 {
            let byteCount = retainedPixelBufferBytes(frames)
            guard frames.count > policy.maximumQueueDepth || byteCount > policy.maximumRetainedPixelBufferBytes else { break }
            let ageMs = frameAgeMs(frames.removeFirst(), now: now)
            result.recordSmoothestDepthDrop(ageMs: ageMs)
            noteInstability(now: now)
        }

        while frames.count > 1,
              let first = frames.first,
              frameAgeMs(first, now: now) > policy.maximumQueueAgeMs {
            let ageMs = frameAgeMs(frames.removeFirst(), now: now)
            result.recordSmoothestAgeDrop(ageMs: ageMs)
            noteInstability(now: now)
        }

        while frames.count > 1,
              let first = frames.first,
              now - effectiveTargetPlayoutTime(for: first, policy: policy) > hardLatenessSeconds(policy: policy) {
            let ageMs = frameAgeMs(frames.removeFirst(), now: now)
            result.recordSmoothestDisplayDebtDrop(ageMs: ageMs)
            noteInstability(now: now)
        }

        if result.smoothestAgeDrops > 0 || result.smoothestDisplayDebtDrops > 0 {
            result.recordSmoothestFifoReset()
        }
        return result
    }

    private mutating func selectBalancedRecoveryFrame(
        from frames: inout [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime,
        trimResult: inout TrimResult
    ) -> MirageRenderFrame? {
        guard policy.latencyMode == .balanced,
              let first = frames.first else {
            return nil
        }

        let oldestAgeMs = frameAgeMs(first, now: now)
        let effectiveTarget = effectiveTargetPlayoutTime(for: first, policy: policy)
        let futureWaitMs = max(0, effectiveTarget - now) * 1000
        let shouldRecover = oldestAgeMs >= policy.smoothestDisplayDebtCapMs ||
            futureWaitMs > policy.maximumTargetPlayoutDelayMs
        guard shouldRecover else { return nil }

        while frames.count > 1 {
            let ageMs = frameAgeMs(frames.removeFirst(), now: now)
            trimResult.recordSmoothestDisplayDebtDrop(ageMs: ageMs)
        }
        trimResult.recordSmoothestFifoReset()
        resetPresentationEpoch(policy: policy, now: now)
        return frames.first
    }

    private mutating func removeSubmittedFrames(
        from frames: inout [MirageRenderFrame],
        after submittedCursor: MirageRenderCursor
    ) -> TrimResult {
        while let first = frames.first, !first.cursor.isAfter(submittedCursor) {
            frames.removeFirst()
        }
        return .empty
    }

    private func frameIsReadyForPlayout(
        _ frame: MirageRenderFrame,
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> Bool {
        now + readinessSlackSeconds(policy: policy) >= effectiveTargetPlayoutTime(for: frame, policy: policy)
    }

    private func effectiveTargetPlayoutTime(
        for frame: MirageRenderFrame,
        policy: MiragePresentationLatencyPolicy
    ) -> CFAbsoluteTime {
        guard let targetPlayoutTime = frame.targetPlayoutTime else { return frame.decodeTime }
        let targetDelayMs = frame.targetPlayoutDelayMs > 0 ? frame.targetPlayoutDelayMs : adaptedDelayMs
        let effectiveDelayMs = policy.effectiveTargetPlayoutDelayMs(adaptedDelayMs: targetDelayMs)
        let reductionSeconds = max(0, targetDelayMs - effectiveDelayMs) / 1000
        return max(frame.decodeTime, targetPlayoutTime - reductionSeconds)
    }

    private mutating func recordBurstPressureIfNeeded(
        frame: MirageRenderFrame,
        queuedFrameCount: Int,
        previousEnqueuedDecodeTime: CFAbsoluteTime,
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) {
        if previousEnqueuedDecodeTime > 0 {
            let decodeDeltaMs = max(0, frame.decodeTime - previousEnqueuedDecodeTime) * 1000
            if decodeDeltaMs < policy.sourceFrameIntervalMs * 0.45 {
                consecutiveBurstFrames += 1
            } else {
                consecutiveBurstFrames = 0
            }
        }

        guard policy.latencyMode != .balanced || policy.usesAwdlRealtimePolicy else { return }
        let expectedDepth = max(1, Int((effectiveDelayMs(policy: policy) / policy.displayFrameIntervalMs).rounded(.up)))
        guard consecutiveBurstFrames >= 2 || queuedFrameCount > expectedDepth + 3 else { return }
        increaseDelay(
            reason: .burst,
            amountMs: max(10, policy.displayFrameIntervalMs),
            policy: policy,
            now: now
        )
        consecutiveBurstFrames = 0
    }

    private mutating func noteStableSample(
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) {
        guard policy.usesBufferedPlayout else { return }
        if stableWindowStartTime <= 0 {
            stableWindowStartTime = now
            return
        }
        let stableWindow = if policy.usesAwdlRealtimePolicy {
            1.5
        } else if policy.latencyMode == .balanced {
            0.75
        } else {
            2.5
        }
        let quietSinceInstability = lastInstabilityTime <= 0 || now - lastInstabilityTime >= stableWindow
        guard quietSinceInstability, now - stableWindowStartTime >= stableWindow else { return }
        let baselineDelayMs = policy.baseTargetPlayoutDelayMs
        guard adaptedDelayMs > baselineDelayMs else {
            stableWindowStartTime = now
            return
        }
        let recoveryStep = if policy.usesAwdlRealtimePolicy {
            max(8, policy.displayFrameIntervalMs * 0.5)
        } else if policy.latencyMode == .balanced {
            max(5, policy.displayFrameIntervalMs)
        } else {
            max(5, policy.displayFrameIntervalMs * 0.5)
        }
        adaptedDelayMs = max(baselineDelayMs, adaptedDelayMs - recoveryStep)
        stableWindowStartTime = now
    }

    private mutating func increaseDelay(
        reason: DelayIncreaseReason,
        amountMs: Double,
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) {
        guard now - lastDelayIncreaseTime >= minimumDelayIncreaseSpacing(reason: reason) else { return }
        adaptedDelayMs = min(policy.maximumTargetPlayoutDelayMs, max(policy.baseTargetPlayoutDelayMs, adaptedDelayMs) + amountMs)
        lastDelayIncreaseTime = now
        noteInstability(now: now)
    }

    private mutating func noteInstability(now: CFAbsoluteTime) {
        lastInstabilityTime = now
        stableWindowStartTime = now
    }

    private func effectiveDelayMs(policy: MiragePresentationLatencyPolicy) -> Double {
        policy.effectiveTargetPlayoutDelayMs(adaptedDelayMs: adaptedDelayMs)
    }

    private func hardLatenessSeconds(policy: MiragePresentationLatencyPolicy) -> CFTimeInterval {
        if policy.usesAwdlRealtimePolicy {
            return max(0.080, min(0.150, policy.maximumTargetPlayoutDelayMs / 1000))
        }
        if policy.latencyMode == .balanced {
            return max(0.025, min(0.080, policy.maximumTargetPlayoutDelayMs / 1000))
        }
        return max(0.050, min(0.150, policy.effectiveTargetPlayoutDelayMs(adaptedDelayMs: adaptedDelayMs) / 2000))
    }

    private mutating func resetPlayoutAnchors() {
        anchorRemotePresentationTime = .invalid
        anchorTargetPlayoutTime = 0
        lastEnqueuedTargetPlayoutTime = 0
        lastEnqueuedDecodeTime = 0
    }

}
