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

    func setDecoderCodec(_ codec: MirageVideoCodec, streamDimensions: (width: Int, height: Int)? = nil) async {
        await decoder.setCodec(codec, streamDimensions: streamDimensions)
    }

    func setDecoderLowPowerEnabled(_ enabled: Bool) async {
        await decoder.setMaximizePowerEfficiencyEnabled(enabled)
    }

    func setPreferredDecoderColorDepth(_ colorDepth: MirageStreamColorDepth) async {
        await decoder.setPreferredOutputColorDepth(colorDepth)
    }

    func primeForIncomingResize(
        dimensionToken: UInt16?,
        streamDimensions: (width: Int, height: Int)? = nil
    )
    async {
        discardQueuedFramesForRecovery()
        if let dimensionToken {
            reassembler.updateExpectedDimensionToken(dimensionToken)
        }
        _ = MirageRenderStreamStore.shared.resetPresentation(
            for: streamID,
            dropPendingFrames: true,
            reason: "incoming-resize"
        )
        reassembler.beginKeyframeWait()
        await decoder.prepareForDimensionChange(
            expectedWidth: streamDimensions?.width,
            expectedHeight: streamDimensions?.height
        )
        MirageLogger.client(
            "Primed resize admission fence for stream \(streamID) " +
                "(dimensionToken=\(dimensionToken.map(String.init) ?? "nil"))"
        )
    }

    /// Reset decoder for new session (e.g., after resize or reconnection)
    func resetForNewSession() async {
        // Drop any queued frames from the previous session to avoid BadData storms.
        await stopTierPromotionProbe()
        cancelMemoryBudgetRecoveryTask()
        stopFirstPresentedFrameMonitor()
        MirageRenderStreamStore.shared.clear(for: streamID)
        _ = MirageRenderStreamStore.shared.requestPresentationRecovery(for: streamID)
        stopFrameProcessingPipeline()
        await decoder.resetForNewSession()
        reassembler.reset()
        streamCadenceClock.reset(targetFPS: streamCadenceTarget.sourceFPS)
        metricsTracker.reset()
        hasDecodedFirstFrame = false
        hasPresentedFirstFrame = false
        resetPostResizeRecoveryTracking(clearResizeRecovery: true)
        resetTerminalStartupFailureTracking()
        decodeSubmissionStressStreak = 0
        decodeSubmissionHealthyStreak = 0
        latestHostMetricsMessage = nil
        lastDecodeSubmissionConstraintWasSourceBound = nil
        lastSourceBoundDiagnosticSignature = nil
        latestHostCadencePressureSample = nil
        latestRenderTelemetrySnapshot = nil
        lastStreamingAnomalyDiagnosticSignature = nil
        lastStreamingAnomalyDiagnosticTime = 0
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
        lastDecodedProgressTime = 0
        presentationProgressRequiresSequenceAdvance = false
        stopFreezeMonitor()
        await startFrameProcessingPipeline()
        if presentationTier == .activeLive {
            await armFirstPresentedFrameAwaiter(reason: "session-reset")
        } else {
            stopFirstPresentedFrameMonitor()
        }
    }

    /// Prepare decoder/reassembler state for an in-place desktop resize without
    /// clearing steady-state metrics or startup history for the active stream.
    func prepareForResize(
        codec: MirageVideoCodec,
        streamDimensions: (width: Int, height: Int)? = nil
    )
    async {
        await stopTierPromotionProbe()
        cancelMemoryBudgetRecoveryTask()
        stopFirstPresentedFrameMonitor()
        stopFrameProcessingPipeline()
        await decoder.setCodec(codec, streamDimensions: streamDimensions)
        await decoder.resetForNewSession()
        reassembler.reset()
        streamCadenceClock.reset(targetFPS: streamCadenceTarget.sourceFPS)
        discardQueuedFramesForRecovery()
        _ = MirageRenderStreamStore.shared.resetPresentation(
            for: streamID,
            dropPendingFrames: true,
            reason: "prepare-resize"
        )
        resetPostResizeRecoveryTracking(clearResizeRecovery: true)
        lastPresentedProgressTime = 0
        lastDecodedProgressTime = 0
        lastPresentedSequenceObserved = 0
        presentationProgressRequiresSequenceAdvance = false
        stopFreezeMonitor()
        await startFrameProcessingPipeline()
    }

    /// Enter post-resize recovery, re-arming keyframe-gated decode admission for each resize episode.
    func beginPostResizeTransition() async {
        resetPostResizeRecoveryTracking(clearResizeRecovery: true)
        discardQueuedFramesForRecovery()
        _ = MirageRenderStreamStore.shared.resetPresentation(
            for: streamID,
            dropPendingFrames: true,
            reason: "post-resize-transition"
        )
        reassembler.beginKeyframeWait()
        await armPostResizeRecoveryWindow(reason: "post-resize")
        MirageLogger.client("Post-resize transition armed for stream \(streamID) (keyframe-gated decode admission)")
    }

    func updateCadenceTarget(
        sourceFPS: Int,
        displayFPS: Int? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        playoutDelayFrames: Int? = nil,
        reason: String = "cadence target update"
    ) async {
        let resolvedSourceFPS: Int
        let resolvedDisplayFPS: Int
        if presentationTier == .passiveSnapshot {
            resolvedSourceFPS = 1
            resolvedDisplayFPS = 1
        } else {
            resolvedSourceFPS = MirageRenderModePolicy.normalizedTargetFPS(sourceFPS)
            resolvedDisplayFPS = MirageRenderModePolicy.normalizedTargetFPS(displayFPS ?? resolvedSourceFPS)
        }
        let resolvedLatencyMode = latencyMode ?? streamCadenceTarget.latencyMode
        let target = MirageStreamCadenceTarget(
            sourceFPS: resolvedSourceFPS,
            displayFPS: resolvedDisplayFPS,
            latencyMode: resolvedLatencyMode,
            playoutDelayFrames: playoutDelayFrames
        )
        let resolvedBaseline = presentationTier == .passiveSnapshot
            ? 1
            : VideoDecoder.baselineDecodeSubmissionLimit(targetFrameRate: target.sourceFPS)
        let targetUnchanged = target == streamCadenceTarget
        let baselineUnchanged = resolvedBaseline == decodeSubmissionBaselineLimit

        streamCadenceTarget = target
        streamCadenceClock.updateTargetFPS(target.sourceFPS)
        decodeSchedulerTargetFPS = target.sourceFPS
        reassembler.setTargetFrameRate(target.sourceFPS)
        reassembler.setLatencyMode(target.latencyMode)
        MirageRenderStreamStore.shared.setCadenceTarget(for: streamID, target: target)

        if targetUnchanged, baselineUnchanged {
            if currentDecodeSubmissionLimit < decodeSubmissionBaselineLimit {
                currentDecodeSubmissionLimit = decodeSubmissionBaselineLimit
            }
            if await decoder.decodeSubmissionLimit != currentDecodeSubmissionLimit {
                await decoder.setDecodeSubmissionLimit(
                    limit: currentDecodeSubmissionLimit,
                    reason: reason
                )
            }
            return
        }

        decodeSubmissionBaselineLimit = resolvedBaseline
        decodeSubmissionStressStreak = 0
        decodeSubmissionHealthyStreak = 0
        lastDecodeSubmissionConstraintWasSourceBound = nil
        lastSourceBoundDiagnosticSignature = nil
        currentDecodeSubmissionLimit = max(1, min(Self.decodeSubmissionMaximumLimit, decodeSubmissionBaselineLimit))
        await decoder.setDecodeSubmissionLimit(
            limit: currentDecodeSubmissionLimit,
            reason: reason
        )
    }

    func updatePresentationTier(_ tier: StreamPresentationTier, targetFPS: Int? = nil) async {
        let previousTier = presentationTier
        presentationTier = tier
        await GlobalDecodeBudgetController.shared.updateTier(streamID: streamID, tier: tier)

        let requestedTargetFPS = targetFPS ?? streamCadenceTarget.sourceFPS
        let resolvedTargetFPS = switch tier {
        case .activeLive:
            max(20, min(120, requestedTargetFPS))
        case .passiveSnapshot:
            1
        }
        await updateCadenceTarget(
            sourceFPS: resolvedTargetFPS,
            displayFPS: resolvedTargetFPS,
            latencyMode: streamCadenceTarget.latencyMode,
            playoutDelayFrames: streamCadenceTarget.playoutDelayFrames,
            reason: "presentation tier update"
        )

        switch tier {
        case .activeLive:
            if !hasPresentedFirstFrame, !awaitingFirstPresentedFrame {
                await armFirstPresentedFrameAwaiter(reason: "tier-promotion")
            }
            if previousTier == .passiveSnapshot {
                await handlePassiveToActivePromotion()
            }
        case .passiveSnapshot:
            await stopTierPromotionProbe()
            await clearKeyframeRecoveryState()
            stopFreezeMonitor()
            consecutiveFreezeRecoveries = 0
            if !hasPresentedFirstFrame {
                stopFirstPresentedFrameMonitor()
            }
        }
    }

    private func handlePassiveToActivePromotion() async {
        let forcedKeyframeReason: String? = if !hasPresentedFirstFrame {
            "noPresentedFrame"
        } else if reassembler.isAwaitingKeyframe {
            "awaitingKeyframe"
        } else if !reassembler.hasKeyframeAnchor {
            "noKeyframeAnchor"
        } else {
            nil
        }

        if let forcedKeyframeReason {
            await stopTierPromotionProbe()
            reassembler.beginKeyframeWait()
            await setClientRecoveryStatus(.keyframeRecovery, cause: .manual)
            await enterKeyframeRecoveryIfNeeded(reason: "tier-promotion-\(forcedKeyframeReason)", cause: .manual)
            MirageLogger.client(
                "Tier promotion forcing keyframe for stream \(streamID) (reason: \(forcedKeyframeReason))"
            )
            await requestKeyframeRecoveryIfPossible(reason: .manualRecovery)
        } else {
            MirageLogger.client("Tier promotion using P-frame-first for stream \(streamID)")
            await startTierPromotionProbe()
        }
    }

    private func startTierPromotionProbe() async {
        await stopTierPromotionProbe()
        let baselineSequence = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID).sequence
        await setClientRecoveryStatus(.tierPromotionProbe, cause: .manual)
        tierPromotionProbeTask = Task { [weak self] in
            await self?.runTierPromotionProbe(baselineSequence: baselineSequence)
        }
    }

    func stopTierPromotionProbe() async {
        tierPromotionProbeTask?.cancel()
        tierPromotionProbeTask = nil
        if clientRecoveryStatus == .tierPromotionProbe {
            await setClientRecoveryStatus(.idle)
        }
    }

    private func runTierPromotionProbe(baselineSequence: UInt64) async {
        defer { tierPromotionProbeTask = nil }

        do {
            try await Task.sleep(for: Self.tierPromotionProbeDelay)
        } catch {
            return
        }

        guard presentationTier == .activeLive else { return }

        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        if snapshot.sequence > baselineSequence {
            MirageLogger.client(
                "Tier promotion probe progressed for stream \(streamID) (baseline=\(baselineSequence), latest=\(snapshot.sequence))"
            )
            await setClientRecoveryStatus(.idle)
            return
        }

        let keyframeStarved = reassembler.isAwaitingKeyframe || !reassembler.hasKeyframeAnchor
        if keyframeStarved {
            MirageLogger.client(
                "Tier promotion probe requesting keyframe recovery for stream \(streamID) (no progress)"
            )
            reassembler.beginKeyframeWait()
            await setClientRecoveryStatus(.keyframeRecovery, cause: .manual)
            await enterKeyframeRecoveryIfNeeded(reason: "tier-promotion-probe", cause: .manual)
            await requestKeyframeRecoveryIfPossible(reason: .manualRecovery)
            return
        }

        MirageLogger.client(
            "Tier promotion probe requesting single recovery keyframe for stream \(streamID) (no progress)"
        )
        await setClientRecoveryStatus(.keyframeRecovery, cause: .manual)
        await requestKeyframeRecoveryIfPossible(reason: .manualRecovery)
    }
}
