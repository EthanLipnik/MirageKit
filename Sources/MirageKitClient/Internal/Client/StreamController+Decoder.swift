//
//  StreamController+Decoder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream controller extensions.
//

import Foundation
import MirageKit

extension StreamController {
    // MARK: - Decoder Control

    func setDecoderLowPowerEnabled(_ enabled: Bool) async {
        await decoder.setMaximizePowerEfficiencyEnabled(enabled)
    }

    func setPreferredDecoderBitDepth(_ bitDepth: MirageVideoBitDepth) async {
        preferredDecoderBitDepth = bitDepth
        await decoder.setPreferredOutputBitDepth(bitDepth)
    }

    /// Reset decoder for new session (e.g., after resize or reconnection)
    func resetForNewSession() async {
        // Drop any queued frames from the previous session to avoid BadData storms.
        stopTierPromotionProbe()
        stopFirstPresentedFrameMonitor()
        MirageFrameCache.shared.clear(for: streamID)
        stopFrameProcessingPipeline()
        await decoder.resetForNewSession()
        reassembler.reset()
        metricsTracker.reset()
        hasDecodedFirstFrame = false
        hasPresentedFirstFrame = false
        awaitingFirstFrameAfterResize = false
        decodePausedForLocalResize = false
        lastMetricsLogTime = 0
        lastDecodedFrameTime = 0
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        stopFreezeMonitor()
        await startFrameProcessingPipeline()
        if presentationTier == .activeLive {
            armFirstPresentedFrameAwaiter(reason: "session-reset")
        } else {
            stopFirstPresentedFrameMonitor()
        }
    }

    /// Freeze decode admission while local resize orchestration is in-flight.
    func suspendDecodeForLocalResize() {
        guard !decodePausedForLocalResize else { return }
        decodePausedForLocalResize = true
        clearQueuedFramesForRecovery()
        MirageLogger.client("Local resize decode pause enabled for stream \(streamID)")
    }

    /// Resume decode after local resize orchestration.
    /// Optionally requests an immediate recovery keyframe to reduce first-frame latency.
    func resumeDecodeAfterLocalResize(requestRecoveryKeyframe: Bool) async {
        if decodePausedForLocalResize {
            decodePausedForLocalResize = false
            MirageLogger.client("Local resize decode pause cleared for stream \(streamID)")
        }

        guard requestRecoveryKeyframe else { return }
        beginPostResizeTransition()
        await requestKeyframeRecovery(reason: .manualRecovery)
    }

    /// Enter keyframe-only decode admission until a post-resize first frame is decoded.
    func beginPostResizeTransition() {
        guard !awaitingFirstFrameAfterResize else { return }
        awaitingFirstFrameAfterResize = true
        clearQueuedFramesForRecovery()
        reassembler.enterKeyframeOnlyMode()
        armFirstPresentedFrameAwaiter(reason: "post-resize")
        MirageLogger.client("Post-resize transition armed for stream \(streamID) (keyframe-only decode admission)")
    }

    func logMetricsIfNeeded(decodedFPS: Double, receivedFPS: Double, droppedFrames: UInt64) {
        let now = currentTime()
        guard MirageLogger.isEnabled(.client) else { return }
        guard lastMetricsLogTime == 0 || now - lastMetricsLogTime > 2.0 else { return }
        let decodedText = decodedFPS.formatted(.number.precision(.fractionLength(1)))
        let receivedText = receivedFPS.formatted(.number.precision(.fractionLength(1)))
        MirageLogger
            .client(
                "Client FPS: decoded=\(decodedText), received=\(receivedText), dropped=\(droppedFrames), stream=\(streamID)"
            )
        lastMetricsLogTime = now
    }

    /// Get the reassembler for packet routing
    func getReassembler() -> FrameReassembler {
        reassembler
    }

    func updateDecodeSubmissionLimit(targetFrameRate: Int) async {
        let resolvedTargetFPS = max(1, min(120, targetFrameRate))
        let resolvedBaseline = HEVCDecoder.baselineDecodeSubmissionLimit(targetFrameRate: resolvedTargetFPS)
        let targetUnchanged = resolvedTargetFPS == decodeSchedulerTargetFPS
        let baselineUnchanged = resolvedBaseline == decodeSubmissionBaselineLimit
        if targetUnchanged, baselineUnchanged {
            if currentDecodeSubmissionLimit < decodeSubmissionBaselineLimit {
                currentDecodeSubmissionLimit = decodeSubmissionBaselineLimit
            }
            if await decoder.currentDecodeSubmissionLimit() != currentDecodeSubmissionLimit {
                await decoder.setDecodeSubmissionLimit(
                    limit: currentDecodeSubmissionLimit,
                    reason: "target refresh sync"
                )
            }
            return
        }

        decodeSchedulerTargetFPS = resolvedTargetFPS
        decodeSubmissionBaselineLimit = resolvedBaseline
        decodeSubmissionStressStreak = 0
        decodeSubmissionHealthyStreak = 0
        lastDecodeSubmissionConstraintWasSourceBound = nil
        if currentDecodeSubmissionLimit < decodeSubmissionBaselineLimit {
            currentDecodeSubmissionLimit = decodeSubmissionBaselineLimit
        }
        await decoder.setDecodeSubmissionLimit(
            limit: currentDecodeSubmissionLimit,
            reason: "target refresh update"
        )
    }

    func updatePresentationTier(_ tier: StreamPresentationTier, targetFPS: Int? = nil) async {
        let previousTier = presentationTier
        presentationTier = tier
        await GlobalDecodeBudgetController.shared.updateTier(streamID: streamID, tier: tier)

        let resolvedTargetFPS = max(1, min(120, targetFPS ?? (tier == .activeLive ? 60 : 1)))
        decodeSchedulerTargetFPS = resolvedTargetFPS
        if tier == .passiveSnapshot {
            decodeSubmissionBaselineLimit = 1
        } else {
            decodeSubmissionBaselineLimit = HEVCDecoder.baselineDecodeSubmissionLimit(targetFrameRate: resolvedTargetFPS)
        }
        decodeSubmissionStressStreak = 0
        decodeSubmissionHealthyStreak = 0
        lastDecodeSubmissionConstraintWasSourceBound = nil
        currentDecodeSubmissionLimit = max(1, decodeSubmissionBaselineLimit)
        await decoder.setDecodeSubmissionLimit(limit: currentDecodeSubmissionLimit, reason: "presentation tier update")

        switch tier {
        case .activeLive:
            if !hasPresentedFirstFrame, !awaitingFirstPresentedFrame {
                armFirstPresentedFrameAwaiter(reason: "tier-promotion")
            }
            if previousTier == .passiveSnapshot {
                await handlePassiveToActivePromotion()
            }
        case .passiveSnapshot:
            stopTierPromotionProbe()
            stopKeyframeRecoveryLoop()
            stopFreezeMonitor()
            consecutiveFreezeRecoveries = 0
            if !hasPresentedFirstFrame {
                stopFirstPresentedFrameMonitor()
            }
        }
    }

    private func handlePassiveToActivePromotion() async {
        let decision = streamTierPromotionRecoveryDecision(
            hasPresentedFirstFrame: hasPresentedFirstFrame,
            isAwaitingKeyframe: reassembler.isAwaitingKeyframe(),
            hasKeyframeAnchor: reassembler.hasKeyframeAnchor()
        )

        switch decision {
        case let .forceImmediateKeyframe(reason):
            stopTierPromotionProbe()
            reassembler.enterKeyframeOnlyMode()
            startKeyframeRecoveryLoopIfNeeded()
            MirageLogger.client(
                "Tier promotion forcing keyframe for stream \(streamID) (reason: \(tierPromotionReasonText(reason)))"
            )
            await requestKeyframeRecovery(reason: .manualRecovery)
        case .pFrameFirst:
            MirageLogger.client("Tier promotion using P-frame-first for stream \(streamID)")
            startTierPromotionProbe()
        }
    }

    private func tierPromotionReasonText(_ reason: StreamTierPromotionRecoveryReason) -> String {
        switch reason {
        case .noPresentedFrame:
            "noPresentedFrame"
        case .awaitingKeyframe:
            "awaitingKeyframe"
        case .noKeyframeAnchor:
            "noKeyframeAnchor"
        }
    }

    private func startTierPromotionProbe() {
        stopTierPromotionProbe()
        let baselineSequence = MirageFrameCache.shared.presentationSnapshot(for: streamID).sequence
        tierPromotionProbeTask = Task { [weak self] in
            await self?.runTierPromotionProbe(baselineSequence: baselineSequence)
        }
    }

    private func stopTierPromotionProbe() {
        tierPromotionProbeTask?.cancel()
        tierPromotionProbeTask = nil
    }

    private func runTierPromotionProbe(baselineSequence: UInt64) async {
        defer { tierPromotionProbeTask = nil }

        do {
            try await Task.sleep(for: Self.tierPromotionProbeDelay)
        } catch {
            return
        }

        guard presentationTier == .activeLive else { return }

        let snapshot = MirageFrameCache.shared.presentationSnapshot(for: streamID)
        if snapshot.sequence > baselineSequence {
            MirageLogger.client(
                "Tier promotion probe progressed for stream \(streamID) (baseline=\(baselineSequence), latest=\(snapshot.sequence))"
            )
            return
        }

        let keyframeStarved = reassembler.isAwaitingKeyframe() || !reassembler.hasKeyframeAnchor()
        if keyframeStarved {
            MirageLogger.client(
                "Tier promotion probe requesting keyframe-only recovery for stream \(streamID) (no progress)"
            )
            reassembler.enterKeyframeOnlyMode()
            startKeyframeRecoveryLoopIfNeeded()
            await requestKeyframeRecovery(reason: .manualRecovery)
            return
        }

        MirageLogger.client(
            "Tier promotion probe requesting single recovery keyframe for stream \(streamID) (no progress)"
        )
        await requestKeyframeRecovery(reason: .manualRecovery)
    }

    func applyHostRuntimePolicy(_ policy: MirageStreamPolicy) async {
        let tier: StreamPresentationTier = switch policy.tier {
        case .activeLive:
            .activeLive
        case .passiveSnapshot:
            .passiveSnapshot
        }
        await updatePresentationTier(tier, targetFPS: policy.targetFPS)
    }
}
