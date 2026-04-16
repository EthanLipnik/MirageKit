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
        preferredDecoderColorDepth = colorDepth
        await decoder.setPreferredOutputColorDepth(colorDepth)
    }

    func primeForIncomingResize(
        dimensionToken: UInt16?,
        streamDimensions: (width: Int, height: Int)? = nil
    )
    async {
        clearQueuedFramesForRecovery()
        if let dimensionToken {
            reassembler.updateExpectedDimensionToken(dimensionToken)
        }
        reassembler.enterKeyframeOnlyMode()
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
        stopFirstPresentedFrameMonitor()
        MirageRenderStreamStore.shared.clear(for: streamID)
        stopFrameProcessingPipeline()
        await decoder.resetForNewSession()
        reassembler.reset()
        metricsTracker.reset()
        hasDecodedFirstFrame = false
        hasPresentedFirstFrame = false
        resetPostResizeRecoveryTracking(clearResizeRecovery: true)
        startupHardRecoveryCount = 0
        hasTriggeredTerminalStartupFailure = false
        lastMetricsLogTime = 0
        decodeSubmissionStressStreak = 0
        decodeSubmissionHealthyStreak = 0
        latestHostMetricsMessage = nil
        lastDecodeSubmissionConstraintWasSourceBound = nil
        lastSourceBoundDiagnosticSignature = nil
        latestHostCadencePressureSample = nil
        latestRenderTelemetrySnapshot = nil
        lastStreamingAnomalyDiagnosticSignature = nil
        lastStreamingAnomalyDiagnosticTime = 0
        lastDecodedFrameTime = 0
        lastPresentedSequenceObserved = 0
        lastPresentedProgressTime = 0
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
        stopFirstPresentedFrameMonitor()
        stopFrameProcessingPipeline()
        await decoder.setCodec(codec, streamDimensions: streamDimensions)
        await decoder.resetForNewSession()
        reassembler.reset()
        clearQueuedFramesForRecovery()
        resetPostResizeRecoveryTracking(clearResizeRecovery: true)
        lastDecodedFrameTime = 0
        lastPresentedProgressTime = 0
        lastPresentedSequenceObserved = 0
        stopFreezeMonitor()
        await startFrameProcessingPipeline()
    }

    /// Enter post-resize recovery, re-arming keyframe-only decode admission for each resize episode.
    func beginPostResizeTransition() async {
        resetPostResizeRecoveryTracking(clearResizeRecovery: true)
        clearQueuedFramesForRecovery()
        reassembler.enterKeyframeOnlyMode()
        await armPostResizeRecoveryWindow(reason: "post-resize")
        MirageLogger.client("Post-resize transition armed for stream \(streamID) (keyframe-only decode admission)")
    }

    func logMetricsIfNeeded(decodedFPS: Double, receivedFPS: Double, droppedFrames: UInt64) {
        let now = currentTime()
        guard MirageLogger.isEnabled(.metrics) else { return }
        guard lastMetricsLogTime == 0 || now - lastMetricsLogTime > 2.0 else { return }
        let decodedText = decodedFPS.formatted(.number.precision(.fractionLength(1)))
        let receivedText = receivedFPS.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.metrics(
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
        let resolvedBaseline = VideoDecoder.baselineDecodeSubmissionLimit(targetFrameRate: resolvedTargetFPS)
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
        lastSourceBoundDiagnosticSignature = nil
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
            decodeSubmissionBaselineLimit = VideoDecoder.baselineDecodeSubmissionLimit(targetFrameRate: resolvedTargetFPS)
        }
        decodeSubmissionStressStreak = 0
        decodeSubmissionHealthyStreak = 0
        lastDecodeSubmissionConstraintWasSourceBound = nil
        lastSourceBoundDiagnosticSignature = nil
        currentDecodeSubmissionLimit = max(1, decodeSubmissionBaselineLimit)
        await decoder.setDecodeSubmissionLimit(limit: currentDecodeSubmissionLimit, reason: "presentation tier update")

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
            await stopKeyframeRecoveryLoop()
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
            await stopTierPromotionProbe()
            reassembler.enterKeyframeOnlyMode()
            await setClientRecoveryStatus(.keyframeRecovery)
            await startKeyframeRecoveryLoopIfNeeded()
            MirageLogger.client(
                "Tier promotion forcing keyframe for stream \(streamID) (reason: \(tierPromotionReasonText(reason)))"
            )
            await requestKeyframeRecovery(reason: .manualRecovery)
        case .pFrameFirst:
            MirageLogger.client("Tier promotion using P-frame-first for stream \(streamID)")
            await startTierPromotionProbe()
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

    private func startTierPromotionProbe() async {
        await stopTierPromotionProbe()
        let baselineSequence = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID).sequence
        await setClientRecoveryStatus(.tierPromotionProbe)
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

        let keyframeStarved = reassembler.isAwaitingKeyframe() || !reassembler.hasKeyframeAnchor()
        if keyframeStarved {
            MirageLogger.client(
                "Tier promotion probe requesting keyframe-only recovery for stream \(streamID) (no progress)"
            )
            reassembler.enterKeyframeOnlyMode()
            await setClientRecoveryStatus(.keyframeRecovery)
            await startKeyframeRecoveryLoopIfNeeded()
            await requestKeyframeRecovery(reason: .manualRecovery)
            return
        }

        MirageLogger.client(
            "Tier promotion probe requesting single recovery keyframe for stream \(streamID) (no progress)"
        )
        await setClientRecoveryStatus(.keyframeRecovery)
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
