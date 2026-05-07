//
//  StreamController+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream controller extensions.
//

import CoreGraphics
import Foundation
import MirageKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

extension StreamController {
    struct AdaptiveJitterState: Sendable, Equatable {
        var holdMs: Int
        var stressStreak: Int
        var stableStreak: Int
    }

    // MARK: - Private Helpers

    nonisolated static func frameIntervalSeconds(targetFPS: Int) -> CFAbsoluteTime {
        1.0 / Double(max(1, targetFPS))
    }

    nonisolated static func keyframeRequestCoalesceInterval(targetFPS: Int) -> CFAbsoluteTime {
        let frameScaledInterval = frameIntervalSeconds(targetFPS: targetFPS) * 24.0
        return max(recoveryRequestDispatchCooldown, min(1.0, frameScaledInterval))
    }

    nonisolated static func keyframeProgressFreshThreshold(targetFPS: Int) -> CFAbsoluteTime {
        let frameScaledThreshold = frameIntervalSeconds(targetFPS: targetFPS) * 18.0
        return min(0.50, max(0.15, frameScaledThreshold))
    }

    nonisolated static func keyframeRecoveryEpisodeDeadline(targetFPS: Int) -> CFAbsoluteTime {
        let frameScaledDeadline = frameIntervalSeconds(targetFPS: targetFPS) * 120.0
        return min(4.0, max(1.5, frameScaledDeadline))
    }

    nonisolated static func keyframeRecoveryRetryDelay(
        attempt: Int,
        targetFPS: Int
    )
    -> CFAbsoluteTime {
        let frameInterval = frameIntervalSeconds(targetFPS: targetFPS)
        switch attempt {
        case 0:
            return min(1.0, max(0.25, frameInterval * 18.0))
        case 1:
            return min(1.5, max(0.50, frameInterval * 36.0))
        default:
            return min(2.0, max(1.00, frameInterval * 60.0))
        }
    }

    nonisolated static func duration(seconds: CFAbsoluteTime) -> Duration {
        .milliseconds(Int64(max(1, Int((seconds * 1000).rounded(.up)))))
    }

    func updateHostMetrics(_ metrics: StreamMetricsMessage?) {
        latestHostMetricsMessage = metrics
        latestHostCadencePressureSample = metrics.map(HostCadencePressureDiagnosticSample.init(metrics:))
        if let targetFrameRate = metrics?.targetFrameRate {
            reassembler.setTargetFrameRate(targetFrameRate)
        }
    }

    func handleKeyframeRecoveryAck(_ ack: KeyframeRecoveryAckMessage) {
        recoveryCoordinator.recordHostAck(ack, now: currentTime())
        if ack.accepted {
            realtimeMediaSession.setRecoveryState(.keyframeRecovery)
        }
    }

    func maybeLogStreamingAnomalyDiagnostic(
        trigger: String,
        decodedFPS: Double,
        receivedFPS: Double
    ) async {
        guard MirageLogger.isEnabled(.client) else { return }
        guard !shouldSuppressStartupAnomalyDiagnostic() else { return }

        let renderTelemetry = latestRenderTelemetrySnapshot ??
            MirageRenderStreamStore.shared.renderTelemetrySnapshot(for: streamID)
        let frameMetrics = metricsTracker.snapshot(now: currentTime())
        let reassemblerMetrics = reassembler.snapshotMetrics()
        let diagnostic = clientStreamingAnomalyDiagnostic(
            sample: ClientStreamingAnomalySample(
                streamID: streamID,
                trigger: trigger,
                decodedFPS: decodedFPS,
                receivedFPS: receivedFPS,
                receivedWorstGapMs: frameMetrics.receivedWorstGapMs,
                receivedFrameIntervalP95Ms: frameMetrics.receivedFrameIntervalP95Ms,
                receivedFrameIntervalP99Ms: frameMetrics.receivedFrameIntervalP99Ms,
                displayTickFPS: renderTelemetry.displayTickFPS,
                submitAttemptFPS: renderTelemetry.submitAttemptFPS,
                layerAcceptedFPS: renderTelemetry.layerAcceptedFPS,
                presentedFPS: renderTelemetry.presentedFPS,
                submittedFPS: renderTelemetry.submittedFPS,
                uniqueSubmittedFPS: renderTelemetry.uniqueSubmittedFPS,
                pendingFrameCount: renderTelemetry.pendingFrameCount,
                pendingFrameAgeMs: renderTelemetry.pendingFrameAgeMs,
                overwrittenPendingFrames: renderTelemetry.overwrittenPendingFrames,
                lateFrameDrops: renderTelemetry.lateFrameDrops,
                coalescedBeforeSubmitCount: renderTelemetry.coalescedBeforeSubmitCount,
                duplicateRemoteTimestampCount: renderTelemetry.duplicateRemoteTimestampCount,
                correctedStreamTimestampCount: renderTelemetry.correctedStreamTimestampCount,
                displayLayerNotReadyCount: renderTelemetry.displayLayerNotReadyCount,
                repeatedFrameCount: renderTelemetry.repeatedFrameCount,
                missedVSyncCount: renderTelemetry.missedVSyncCount,
                displayTickIntervalP95Ms: renderTelemetry.displayTickIntervalP95Ms,
                displayTickIntervalP99Ms: renderTelemetry.displayTickIntervalP99Ms,
                playoutDelayFrames: renderTelemetry.playoutDelayFrames,
                presentationStallCount: renderTelemetry.presentationStallCount,
                worstPresentationGapMs: renderTelemetry.worstPresentationGapMs,
                frameIntervalP95Ms: renderTelemetry.frameIntervalP95Ms,
                frameIntervalP99Ms: renderTelemetry.frameIntervalP99Ms,
                decodeHealthy: renderTelemetry.decodeHealthy,
                decodeSubmissionLimit: currentDecodeSubmissionLimit,
                presentationTier: presentationTier,
                reassemblerPendingFrameCount: reassemblerMetrics.pendingFrameCount,
                reassemblerPendingKeyframeCount: reassemblerMetrics.pendingKeyframeCount,
                reassemblerPendingBytes: reassemblerMetrics.pendingFrameBytes,
                frameBufferPoolRetainedBytes: reassemblerMetrics.frameBufferPoolRetainedBytes,
                reassemblerBudgetEvictions: reassemblerMetrics.budgetEvictions,
                decoderOutputPixelFormat: await decoder.decodedOutputPixelFormatName(),
                usingHardwareDecoder: await decoder.currentHardwareDecoderStatus(),
                targetFrameRate: max(1, latestHostMetricsMessage?.targetFrameRate ?? streamCadenceTarget.sourceFPS),
                sourceTargetFrameRate: max(1, streamCadenceTarget.sourceFPS),
                displayTargetFrameRate: max(1, streamCadenceTarget.displayFPS),
                hostMetrics: latestHostMetricsMessage
            )
        )
        let signature = "\(trigger)|\(diagnostic.signature)"
        let now = currentTime()
        if signature == lastStreamingAnomalyDiagnosticSignature,
           lastStreamingAnomalyDiagnosticTime > 0,
           now - lastStreamingAnomalyDiagnosticTime < Self.streamingAnomalyLogCooldown {
            return
        }

        lastStreamingAnomalyDiagnosticSignature = signature
        lastStreamingAnomalyDiagnosticTime = now
        MirageLogger.client(diagnostic.message)
    }

    func shouldSuppressStartupAnomalyDiagnostic() -> Bool {
        guard presentationTier == .activeLive else { return false }
        guard hasPresentedFirstFrame else { return true }
        guard latestHostMetricsMessage == nil else { return false }
        let firstPresentationTime = lastPresentedProgressTime
        guard firstPresentationTime > 0 else { return true }
        let sampleWindow = max(
            0.50,
            Self.frameIntervalSeconds(targetFPS: streamCadenceTarget.sourceFPS) * 12.0
        )
        return currentTime() - firstPresentationTime < sampleWindow
    }

    func setTransportPathKind(_ kind: MirageNetworkPathKind) {
        let awdlActive = awdlExperimentEnabled && kind == .awdl
        guard awdlTransportActive != awdlActive else { return }
        awdlTransportActive = awdlActive
        if !awdlActive {
            adaptiveJitterHoldMs = 0
            adaptiveJitterStressStreak = 0
            adaptiveJitterStableStreak = 0
        }
    }

    func evaluateAdaptiveJitterHold(receivedFPS: Double) {
        guard awdlExperimentEnabled, awdlTransportActive else {
            guard adaptiveJitterHoldMs != 0 ||
                adaptiveJitterStressStreak != 0 ||
                adaptiveJitterStableStreak != 0 else {
                return
            }
            adaptiveJitterHoldMs = 0
            adaptiveJitterStressStreak = 0
            adaptiveJitterStableStreak = 0
            return
        }

        let state = Self.nextAdaptiveJitterState(
            current: AdaptiveJitterState(
                holdMs: adaptiveJitterHoldMs,
                stressStreak: adaptiveJitterStressStreak,
                stableStreak: adaptiveJitterStableStreak
            ),
            receivedFPS: receivedFPS,
            targetFPS: decodeSchedulerTargetFPS
        )
        guard state.holdMs != adaptiveJitterHoldMs ||
            state.stressStreak != adaptiveJitterStressStreak ||
            state.stableStreak != adaptiveJitterStableStreak else {
            return
        }
        adaptiveJitterHoldMs = state.holdMs
        adaptiveJitterStressStreak = state.stressStreak
        adaptiveJitterStableStreak = state.stableStreak
    }

    nonisolated static func nextAdaptiveJitterState(
        current: AdaptiveJitterState,
        receivedFPS: Double,
        targetFPS: Int
    ) -> AdaptiveJitterState {
        var next = current
        let target = Double(max(1, targetFPS))
        let stress = receivedFPS < target * Self.adaptiveJitterStressThreshold
        if stress {
            next.stressStreak += 1
            next.stableStreak = 0
            if next.stressStreak >= Self.adaptiveJitterStressWindows {
                next.stressStreak = 0
                next.holdMs = min(
                    Self.adaptiveJitterHoldMaxMs,
                    next.holdMs + Self.adaptiveJitterStepUpMs
                )
            }
            return next
        }

        next.stressStreak = 0
        next.stableStreak += 1
        if next.stableStreak >= Self.adaptiveJitterStableWindows {
            next.stableStreak = 0
            next.holdMs = max(0, next.holdMs - Self.adaptiveJitterStepDownMs)
        }
        return next
    }

    @discardableResult
    func syncPresentationProgressFromFrameStore(now: CFAbsoluteTime? = nil) -> Bool {
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        let referenceNow = now ?? currentTime()

        if snapshot.sequence > lastPresentedSequenceObserved {
            lastPresentedSequenceObserved = snapshot.sequence
            lastPresentedProgressTime = snapshot.submittedTime > 0 ? snapshot.submittedTime : referenceNow
            presentationProgressRequiresSequenceAdvance = false
            return true
        }

        if lastPresentedProgressTime == 0 {
            if snapshot.submittedTime > 0 {
                lastPresentedSequenceObserved = max(lastPresentedSequenceObserved, snapshot.sequence)
                lastPresentedProgressTime = snapshot.submittedTime
                presentationProgressRequiresSequenceAdvance = false
                return true
            }

            if hasPresentedFirstFrame, !presentationProgressRequiresSequenceAdvance {
                lastPresentedProgressTime = referenceNow
                return true
            }
        }

        return false
    }

    nonisolated static func shouldClearRecoveryStatusOnPresentationProgress(
        _ status: MirageStreamClientRecoveryStatus
    ) -> Bool {
        switch status {
        case .tierPromotionProbe,
             .keyframeRecovery,
             .hardRecovery:
            true
        case .idle,
             .startup,
             .postResizeAwaitingFirstFrame:
            false
        }
    }

    nonisolated static func shouldSuppressPostResizeDecodeErrorRecovery(
        awaitingFirstFrameAfterResize: Bool,
        graceDeadline: CFAbsoluteTime,
        now: CFAbsoluteTime
    ) -> Bool {
        awaitingFirstFrameAfterResize && graceDeadline > 0 && now < graceDeadline
    }

    func resetPostResizeRecoveryTracking(clearResizeRecovery: Bool) {
        postResizeDecodeRecoverySuccessCount = 0
        if clearResizeRecovery {
            awaitingFirstFrameAfterResize = false
            awaitingFirstPresentedFrameAfterResize = false
            postResizeDecodeErrorGraceDeadline = 0
        }
    }

    func armPostResizeRecoveryWindow(reason: String) async {
        postResizeRecoveryEpisodeID &+= 1
        awaitingFirstFrameAfterResize = true
        awaitingFirstPresentedFrameAfterResize = true
        postResizeDecodeRecoverySuccessCount = 0
        postResizeDecodeErrorGraceDeadline = currentTime() + Self.postResizeDecodeErrorGraceInterval
        await decoder.beginRecoveryTracking()
        await setClientRecoveryStatus(.postResizeAwaitingFirstFrame)
        if presentationTier == .activeLive {
            await armFirstPresentedFrameAwaiter(reason: reason, mode: .recovery)
        }
    }

    func handleDecoderRecoverySignal() async {
        guard awaitingFirstFrameAfterResize else { return }
        postResizeDecodeRecoverySuccessCount = Self.postResizeDecodeRecoverySuccessThreshold
        MirageLogger.client(
            "Post-resize decoder recovery streak complete for stream \(streamID)"
        )
        await maybeCompletePostResizeRecovery()
    }

    func maybeCompletePostResizeRecovery() async {
        guard awaitingFirstFrameAfterResize else { return }
        guard !awaitingFirstPresentedFrameAfterResize else { return }
        guard postResizeDecodeRecoverySuccessCount >= Self.postResizeDecodeRecoverySuccessThreshold else { return }
        awaitingFirstFrameAfterResize = false
        postResizeDecodeErrorGraceDeadline = 0
        MirageLogger.client("Post-resize recovery stabilized for stream \(streamID)")
        if clientRecoveryStatus == .postResizeAwaitingFirstFrame {
            await setClientRecoveryStatus(.idle)
        }
    }

    func clearTransientRecoveryStateAfterPresentationProgress() async {
        cancelMemoryBudgetRecoveryTask()
        recoveryCoordinator.recordProgress()
        guard Self.shouldClearRecoveryStatusOnPresentationProgress(clientRecoveryStatus) else { return }

        switch clientRecoveryStatus {
        case .keyframeRecovery:
            MirageLogger.client(
                "Presentation progress resumed for stream \(streamID); ending keyframe recovery"
            )
            await stopKeyframeRecoveryLoop()
        case .hardRecovery:
            MirageLogger.client(
                "Presentation progress resumed for stream \(streamID); ending hard recovery"
            )
            presentationProgressRequiresSequenceAdvance = false
            await stopKeyframeRecoveryLoop()
            await setClientRecoveryStatus(.idle)
        case .tierPromotionProbe:
            MirageLogger.client(
                "Presentation progress resumed for stream \(streamID); ending tier-promotion probe"
            )
            await stopTierPromotionProbe()
        case .idle,
             .startup,
             .postResizeAwaitingFirstFrame:
            break
        }
    }

    func armFirstPresentedFrameAwaiter(
        reason: String,
        mode: FirstPresentedFrameAwaitMode = .startup
    ) async {
        guard !hasTriggeredTerminalStartupFailure else { return }
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        awaitingFirstPresentedFrame = true
        firstPresentedFrameAwaitMode = mode
        firstPresentedFrameBaselineSequence = snapshot.sequence
        firstPresentedFrameWaitReason = reason
        firstPresentedFrameWaitStartTime = currentTime()
        firstPresentedFrameLastWaitLogTime = firstPresentedFrameWaitStartTime
        firstPresentedFrameLastRecoveryRequestTime = 0
        firstPresentedFrameRecoveryAttemptCount = 0
        firstPresentedFrameRendererRecoveryAttemptCount = 0
        reassembler.setStartupKeyframeTimeoutOverrideEnabled(true)
        if reason != "post-resize", mode == .startup {
            await setClientRecoveryStatus(.startup)
        }

        MirageLogger
            .client(
                "Waiting for first presented frame (\(reason)) for stream \(streamID), baseline sequence \(snapshot.sequence)"
            )
        startFirstPresentedFrameMonitorIfNeeded()
    }

    func stopFirstPresentedFrameMonitor() {
        firstPresentedFrameTask?.cancel()
        firstPresentedFrameTask = nil
        awaitingFirstPresentedFrame = false
        firstPresentedFrameAwaitMode = .startup
        firstPresentedFrameBaselineSequence = 0
        firstPresentedFrameWaitReason = nil
        firstPresentedFrameWaitStartTime = 0
        firstPresentedFrameLastWaitLogTime = 0
        firstPresentedFrameLastRecoveryRequestTime = 0
        firstPresentedFrameRecoveryAttemptCount = 0
        firstPresentedFrameRendererRecoveryAttemptCount = 0
        reassembler.setStartupKeyframeTimeoutOverrideEnabled(false)
    }

    func markFirstFrameDecoded() async {
        let shouldNotify = !hasDecodedFirstFrame
        if !hasDecodedFirstFrame {
            hasDecodedFirstFrame = true
        }

        if awaitingFirstFrameAfterResize {
            MirageLogger.client("Post-resize first frame decoded for stream \(streamID)")
        }

        guard shouldNotify, let handler = onFirstFrameDecoded else { return }
        await MainActor.run {
            handler()
        }
    }

    func markFirstFramePresented() async {
        let now = currentTime()
        let wasAwaitingFirstPresentation = awaitingFirstPresentedFrame
        let waitStart = firstPresentedFrameWaitStartTime

        awaitingFirstPresentedFrame = false
        firstPresentedFrameBaselineSequence = 0
        firstPresentedFrameWaitStartTime = 0
        firstPresentedFrameLastWaitLogTime = 0
        firstPresentedFrameLastRecoveryRequestTime = 0
        firstPresentedFrameRecoveryAttemptCount = 0
        firstPresentedFrameRendererRecoveryAttemptCount = 0
        startupHardRecoveryCount = 0
        hasTriggeredTerminalStartupFailure = false
        reassembler.setStartupKeyframeTimeoutOverrideEnabled(false)

        if awaitingFirstFrameAfterResize {
            awaitingFirstPresentedFrameAfterResize = false
            if waitStart > 0 {
                let elapsedMs = Int((now - waitStart) * 1000)
                MirageLogger.client(
                    "Post-resize first frame presented for stream \(streamID) (+\(elapsedMs)ms)"
                )
            } else {
                MirageLogger.client("Post-resize first frame presented for stream \(streamID)")
            }
        }

        let shouldNotify = !hasPresentedFirstFrame || wasAwaitingFirstPresentation
        if !hasPresentedFirstFrame {
            hasPresentedFirstFrame = true
        }
        presentationProgressRequiresSequenceAdvance = false
        if !hasDecodedFirstFrame {
            hasDecodedFirstFrame = true
        }
        syncPresentationProgressFromFrameStore(now: now)
        if awaitingFirstFrameAfterResize {
            await maybeCompletePostResizeRecovery()
        } else {
            await setClientRecoveryStatus(.idle)
        }
        guard shouldNotify, let handler = onFirstFramePresented else { return }
        await MainActor.run {
            handler()
        }
    }

    private func startFirstPresentedFrameMonitorIfNeeded() {
        guard firstPresentedFrameTask == nil else { return }
        firstPresentedFrameTask = Task { [weak self] in
            guard let self else { return }
            await self.runFirstPresentedFrameMonitor()
        }
    }

    private func runFirstPresentedFrameMonitor() async {
        defer { firstPresentedFrameTask = nil }

        while !Task.isCancelled {
            guard awaitingFirstPresentedFrame else { return }

            let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
            if snapshot.sequence > firstPresentedFrameBaselineSequence {
                await markFirstFramePresented()
                return
            }

            let now = currentTime()
            maybeLogFirstPresentedFrameWait(now: now, latestSequence: snapshot.sequence)
            await maybeTriggerBootstrapFirstFrameRecovery(now: now, latestSequence: snapshot.sequence)

            do {
                try await Task.sleep(for: Self.firstPresentedFramePollInterval)
            } catch {
                return
            }
        }
    }

    private func maybeLogFirstPresentedFrameWait(now: CFAbsoluteTime, latestSequence: UInt64) {
        guard awaitingFirstPresentedFrame else { return }
        guard firstPresentedFrameWaitStartTime > 0 else { return }
        guard now - firstPresentedFrameLastWaitLogTime >= Self.firstPresentedFrameWaitLogInterval else { return }

        firstPresentedFrameLastWaitLogTime = now
        let elapsedMs = Int((now - firstPresentedFrameWaitStartTime) * 1000)
        let pendingDepth = MirageRenderStreamStore.shared.pendingFrameCount(for: streamID)
        let awaitingKeyframe = reassembler.isAwaitingKeyframe()
        let reason = firstPresentedFrameWaitReason ?? "unknown"
        MirageLogger
            .client(
                "Still waiting for first presented frame (\(reason)) for stream \(streamID) (+\(elapsedMs)ms, " +
                    "baseline=\(firstPresentedFrameBaselineSequence), latest=\(latestSequence), " +
                    "pendingFrames=\(pendingDepth), awaitingKeyframe=\(awaitingKeyframe))"
            )
    }

    private func maybeTriggerBootstrapFirstFrameRecovery(
        now: CFAbsoluteTime,
        latestSequence: UInt64
    ) async {
        guard awaitingFirstPresentedFrame,
              firstPresentedFrameWaitStartTime > 0 else { return }
        let elapsed = now - firstPresentedFrameWaitStartTime
        let recoveryGrace = Self.firstPresentedFrameBootstrapRecoveryGrace(for: firstPresentedFrameAwaitMode)
        guard elapsed >= recoveryGrace else { return }
        guard firstPresentedFrameLastRecoveryRequestTime == 0
           || now - firstPresentedFrameLastRecoveryRequestTime >= Self.firstPresentedFrameRecoveryCooldown else { return }

        if reassembler.isAwaitingKeyframe(),
           let pendingKeyframeProgress = reassembler.latestPendingKeyframeProgress(),
           now - pendingKeyframeProgress.lastProgressTime < Self.keyframeProgressFreshThreshold(
               targetFPS: decodeSchedulerTargetFPS
           ) {
            return
        }

        let pendingFrameCount = MirageRenderStreamStore.shared.pendingFrameCount(for: streamID)
        if Self.shouldAttemptRendererRecoveryBeforeBootstrapReset(
            pendingFrameCount: pendingFrameCount,
            submittedSequence: latestSequence,
            baselineSequence: firstPresentedFrameBaselineSequence,
            rendererRecoveryAttempts: firstPresentedFrameRendererRecoveryAttemptCount
        ) {
            firstPresentedFrameRendererRecoveryAttemptCount &+= 1
            let didRequestPresenterRecovery = MirageRenderStreamStore.shared.requestPresentationRecovery(for: streamID)
            if didRequestPresenterRecovery {
                firstPresentedFrameLastRecoveryRequestTime = now
                MirageLogger.client(
                    "Startup first-frame presenter recovery requested for stream \(streamID) " +
                        "(pendingFrames=\(pendingFrameCount), submitted=0)"
                )
                return
            }
            MirageLogger.client(
                "Startup first-frame presenter recovery had no active handler for stream \(streamID) " +
                    "(pendingFrames=\(pendingFrameCount), submitted=0)"
            )
        }

        let hasPackets = reassembler.hasReceivedPackets()
        let awaitingKeyframe = reassembler.isAwaitingKeyframe()
        let startupStallKind: String
        if awaitingKeyframe {
            startupStallKind = "reassembler awaiting keyframe"
        } else if !hasPackets {
            startupStallKind = "no startup packets received"
        } else if latestSequence <= firstPresentedFrameBaselineSequence {
            startupStallKind = "no presented frame progress"
        } else {
            startupStallKind = "startup presentation stalled"
        }

        firstPresentedFrameLastRecoveryRequestTime = now
        firstPresentedFrameRecoveryAttemptCount &+= 1

        let recoveryAction = Self.bootstrapFirstFrameRecoveryAction(
            hasPackets: hasPackets,
            awaitingKeyframe: awaitingKeyframe,
            latestSequence: latestSequence,
            baselineSequence: firstPresentedFrameBaselineSequence
        )

        if firstPresentedFrameRecoveryAttemptCount >= Self.firstPresentedFrameHardRecoveryThreshold ||
            recoveryAction == .hardRecovery {
            MirageLogger.client(
                "Bootstrap first frame recovery escalating to hard reset for stream \(streamID) "
                    + "(waited \(Int(elapsed * 1000))ms, \(startupStallKind))"
            )
            await requestRecovery(
                reason: .startupKeyframeTimeout,
                restartRecoveryLoop: false,
                awaitFirstPresentedFrame: true,
                firstPresentedFrameWaitReason: "startup-hard-recovery"
            )
            return
        }

        MirageLogger.client(
            "Bootstrap first frame recovery: requesting keyframe for stream \(streamID) "
                + "(waited \(Int(elapsed * 1000))ms, \(startupStallKind), transport=healthy-packet-flow)"
        )
        await requestKeyframeRecovery(reason: .startupKeyframeTimeout)
    }

    func recordDecodedFrame() async {
        lastDecodedFrameTime = currentTime()
        if !decodeRecoveryEscalationTimestamps.isEmpty {
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
        }
        if awaitingFirstFrameAfterResize {
            let shouldNotify = postResizeDecodeRecoverySuccessCount == 0
            postResizeDecodeRecoverySuccessCount = min(
                Self.postResizeDecodeRecoverySuccessThreshold,
                postResizeDecodeRecoverySuccessCount + 1
            )
            if shouldNotify {
                MirageLogger.client("Post-resize decoded frame arrived for stream \(streamID)")
                let handler = onPostResizeFrameDecoded
                await MainActor.run {
                    handler?()
                }
            }
            if postResizeDecodeRecoverySuccessCount >= Self.postResizeDecodeRecoverySuccessThreshold {
                awaitingFirstPresentedFrameAfterResize = false
                await maybeCompletePostResizeRecovery()
            }
        }
        if presentationTier == .activeLive,
           !hasPresentedFirstFrame,
           !awaitingFirstPresentedFrame {
            await armFirstPresentedFrameAwaiter(reason: "decode-without-presentation")
        }
        if presentationTier == .activeLive {
            startFreezeMonitorIfNeeded()
        } else {
            stopFreezeMonitor()
            lastPresentedProgressTime = currentTime()
            consecutiveFreezeRecoveries = 0
        }
    }

    func recordQueueDrop() {
        queueDropsSinceLastLog += 1
        metricsTracker.recordQueueDrop()
    }

    func maybeLogDecodeBackpressure(queueDepth: Int) {
        let now = currentTime()
        if lastBackpressureLogTime > 0,
           now - lastBackpressureLogTime < Self.backpressureLogCooldown {
            return
        }
        lastBackpressureLogTime = now
        MirageLogger.client(
            "Decode backpressure threshold hit (depth \(queueDepth)) for stream \(streamID); " +
                "continuing decode without keyframe recovery"
        )
    }

    func handleFrameLossSignal(
        reason: FrameReassembler.FrameLossReason = .timeout
    ) async {
        if let diagnostic = Self.frameLossDiagnosticMessage(streamID: streamID, reason: reason) {
            MirageLogger.client(diagnostic)
        }
        if reason == .severeForwardGap {
            let metricsSnapshot = metricsTracker.snapshot(now: currentTime())
            await maybeLogStreamingAnomalyDiagnostic(
                trigger: "frame-loss-\(reason.rawValue)",
                decodedFPS: metricsSnapshot.decodedFPS,
                receivedFPS: metricsSnapshot.receivedFPS
            )
        }
        if !hasDecodedFirstFrame || !hasPresentedFirstFrame {
            if presentationTier == .activeLive, !awaitingFirstPresentedFrame {
                await armFirstPresentedFrameAwaiter(reason: "frame-loss-bootstrap")
            }
            let now = currentTime()
            firstPresentedFrameLastRecoveryRequestTime = now
            firstPresentedFrameRecoveryAttemptCount = max(1, firstPresentedFrameRecoveryAttemptCount)
            MirageLogger.client(
                "Frame loss detected before first frame for stream \(streamID) reason=\(reason.rawValue); requesting bootstrap recovery keyframe"
            )
            await requestKeyframeRecovery(reason: .startupKeyframeTimeout)
            return
        }

        if presentationTier == .passiveSnapshot {
            reassembler.enterKeyframeOnlyMode()
            MirageLogger.client(
                "Frame loss detected for passive stream \(streamID); entering keyframe-only mode"
            )
            return
        }

        if reason.requestsImmediateActiveRecovery {
            reassembler.enterKeyframeOnlyMode()
            MirageLogger.client(
                "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); requesting immediate recovery keyframe"
            )
            await startKeyframeRecoveryLoopIfNeeded()
            await requestKeyframeRecovery(reason: .frameLoss)
            return
        }

        if reason == .memoryBudget {
            reassembler.enterKeyframeOnlyMode()
            clearQueuedFramesForRecovery()
            startFreezeMonitorIfNeeded()
            if memoryBudgetRecoveryTask != nil {
                MirageLogger.client(
                    "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); " +
                        "memory-budget recovery already settling"
                )
                return
            }
            scheduleMemoryBudgetRecoveryIfNeeded()
            MirageLogger.client(
                "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); deferring recovery keyframe while memory pressure settles"
            )
            return
        }

        if reason == .timeout, reassembler.isAwaitingKeyframe() {
            guard !hasPresentedFirstFrame else {
                startFreezeMonitorIfNeeded()
                MirageLogger.client(
                    "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); " +
                        "reassembler is awaiting keyframe after presentation progress, waiting for freeze recovery"
                )
                return
            }
            MirageLogger.client(
                "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); " +
                    "reassembler is awaiting keyframe before first presentation, requesting bounded recovery"
            )
            await startKeyframeRecoveryLoopIfNeeded()
            await requestKeyframeRecovery(reason: .frameLoss)
            return
        }

        // Active streams avoid keyframe requests for non-blocking packet loss.
        // Once the reassembler enters keyframe wait, the timeout branch above
        // requests bounded recovery because dependent P-frames cannot resume decoding.
        MirageLogger.client(
            "Frame loss detected for stream \(streamID) reason=\(reason.rawValue); waiting for natural keyframe or decode error"
        )
    }

    nonisolated static func frameLossDiagnosticMessage(
        streamID: StreamID,
        reason: FrameReassembler.FrameLossReason
    ) -> String? {
        guard reason == .severeForwardGap else { return nil }
        return "Severe forward gap recovery fired for stream \(streamID); treating this as a short gap-recovery dip rather than a sustained host cadence collapse"
    }

    func cancelMemoryBudgetRecoveryTask() {
        memoryBudgetRecoveryTask?.cancel()
        memoryBudgetRecoveryTask = nil
    }

    private func scheduleMemoryBudgetRecoveryIfNeeded() {
        guard presentationTier == .activeLive,
              hasPresentedFirstFrame,
              memoryBudgetRecoveryTask == nil else { return }

        let baselineSequence = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID).sequence
        memoryBudgetRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.memoryBudgetRecoveryDelay)
            } catch {
                return
            }
            await self?.requestMemoryBudgetRecoveryIfStillStalled(baselineSequence: baselineSequence)
        }
    }

    private func requestMemoryBudgetRecoveryIfStillStalled(baselineSequence: UInt64) async {
        memoryBudgetRecoveryTask = nil
        guard !isStopping,
              presentationTier == .activeLive,
              hasPresentedFirstFrame,
              reassembler.isAwaitingKeyframe() else { return }

        let now = currentTime()
        syncPresentationProgressFromFrameStore(now: now)
        let currentSequence = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID).sequence
        guard currentSequence <= baselineSequence else { return }

        if let pendingKeyframeProgress = reassembler.latestPendingKeyframeProgress(),
           now - pendingKeyframeProgress.lastProgressTime < Self.keyframeProgressFreshThreshold(
               targetFPS: decodeSchedulerTargetFPS
           ) {
            return
        }

        MirageLogger.client(
            "Memory-budget recovery requesting a single keyframe for stream \(streamID) after deferred stall check"
        )
        await requestKeyframeRecovery(reason: .memoryBudget)
    }

    @discardableResult
    func requestKeyframeRecovery(reason: RecoveryReason) async -> Bool {
        let now = currentTime()
        let coalesceInterval = Self.keyframeRequestCoalesceInterval(targetFPS: decodeSchedulerTargetFPS)
        if lastRecoveryRequestDispatchTime > 0,
           now - lastRecoveryRequestDispatchTime < coalesceInterval {
            return false
        }
        if shouldDeferKeyframeRequestForPendingProgress(now: now, reason: reason) {
            return false
        }
        let recoveryDecision = recoveryCoordinator.requestAction(
            now: now,
            reason: reason.logLabel,
            targetFPS: decodeSchedulerTargetFPS,
            forceNewEpisode: reason == .manualRecovery || reason == .startupKeyframeTimeout
        )
        switch recoveryDecision {
        case .dispatch:
            break
        case let .wait(deadline):
            let remainingMs = Int(max(0, deadline - now) * 1000)
            MirageLogger.client(
                "Recovery keyframe deferred until retry deadline " +
                    "(\(reason.logLabel), \(remainingMs)ms remaining) for stream \(streamID)"
            )
            return false
        }
        lastRecoveryRequestDispatchTime = now
        lastRecoveryRequestTime = now
        if keyframeRecoveryTask != nil, reason != .keyframeRecoveryLoop {
            keyframeRecoveryAttempt = max(1, keyframeRecoveryAttempt)
        }

        guard let handler = onKeyframeNeeded else { return false }
        MirageLogger.client("Requesting recovery keyframe (\(reason.logLabel)) for stream \(streamID)")
        await MainActor.run {
            handler()
        }
        return true
    }

    private func shouldDeferKeyframeRequestForPendingProgress(
        now: CFAbsoluteTime,
        reason: RecoveryReason
    ) -> Bool {
        guard reason != .manualRecovery else { return false }
        guard reassembler.isAwaitingKeyframe(),
              let pendingKeyframeProgress = reassembler.latestPendingKeyframeProgress() else {
            return false
        }
        return now - pendingKeyframeProgress.lastProgressTime <
            Self.keyframeProgressFreshThreshold(targetFPS: decodeSchedulerTargetFPS)
    }

    func handleDecodeErrorThresholdSignal() async {
        guard !hasTriggeredTerminalStartupFailure else { return }
        if awaitingFirstFrameAfterResize {
            resetPostResizeRecoveryTracking(clearResizeRecovery: false)
        }

        if presentationTier == .passiveSnapshot {
            await requestSoftRecovery(reason: .decodeErrorThreshold)
            return
        }

        let now = currentTime()
        if Self.shouldSuppressPostResizeDecodeErrorRecovery(
            awaitingFirstFrameAfterResize: awaitingFirstFrameAfterResize,
            graceDeadline: postResizeDecodeErrorGraceDeadline,
            now: now
        ) {
            return
        }
        if awaitingFirstFrameAfterResize {
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
            MirageLogger.client(
                "Post-resize decode error threshold exceeded after grace for stream \(streamID); requesting immediate soft recovery"
            )
            await requestSoftRecovery(reason: .decodeErrorThreshold)
            return
        }
        if shouldAttemptStartupDecodeErrorRecovery() {
            firstPresentedFrameLastRecoveryRequestTime = now
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
            MirageLogger.client(
                "Decode error threshold observed before first presented frame for stream \(streamID); forcing startup hard recovery"
            )
            await requestRecovery(reason: .decodeErrorThreshold)
            return
        }

        guard shouldAttemptDecodeErrorRecovery(now: now) else {
            maybeLogDeferredDecodeErrorRecovery(now: now)
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
            return
        }

        decodeRecoveryEscalationTimestamps.append(now)
        trimDecodeRecoveryEscalationWindow(now: now)

        let shouldEscalate = decodeRecoveryEscalationTimestamps.count >= Self.decodeRecoveryEscalationThreshold
        if shouldEscalate {
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
            MirageLogger.client(
                "Decode error storm persisted for stream \(streamID); escalating to hard recovery"
            )
            await requestRecovery(reason: .decodeErrorThreshold)
            return
        }

        await requestSoftRecovery(reason: .decodeErrorThreshold)
    }

    func failStartupRecovery(reason: RecoveryReason) async {
        guard !hasTriggeredTerminalStartupFailure else { return }

        let failure = TerminalStartupFailure(
            reason: reason,
            hardRecoveryAttempts: startupHardRecoveryCount,
            waitReason: firstPresentedFrameWaitReason
        )
        let waitReason = failure.waitReason ?? "unknown"

        hasTriggeredTerminalStartupFailure = true
        isRunning = false
        stopFrameProcessingPipeline()
        stopMetricsReporting()
        stopFreezeMonitor()
        await stopTierPromotionProbe()
        await stopKeyframeRecoveryLoop()
        stopFirstPresentedFrameMonitor()
        await setClientRecoveryStatus(.idle)

        MirageLogger.error(
            .client,
            "Startup recovery exhausted for stream \(streamID) after \(failure.hardRecoveryAttempts) hard recovery attempt(s) " +
                "(reason=\(failure.reason.logLabel), waitReason=\(waitReason))"
        )

        guard let onTerminalStartupFailure else { return }
        await MainActor.run {
            onTerminalStartupFailure(failure)
        }
    }

    func shouldAttemptStartupDecodeErrorRecovery() -> Bool {
        guard !hasPresentedFirstFrame else { return false }
        return awaitingFirstPresentedFrame
    }

    func forcePresentationStallForTesting(now: CFAbsoluteTime? = nil) {
        let referenceNow = now ?? currentTime()
        if !hasPresentedFirstFrame {
            hasPresentedFirstFrame = true
        }
        lastPresentedProgressTime = referenceNow - Self.freezeTimeout - 0.5
    }

    func shouldAttemptDecodeErrorRecovery(now: CFAbsoluteTime) -> Bool {
        let keyframeStarved = reassembler.isAwaitingKeyframe()

        if hasPresentedFirstFrame {
            syncPresentationProgressFromFrameStore(now: now)
            guard lastPresentedProgressTime > 0 else { return false }
            let lastPacketTime = reassembler.latestPacketReceivedTime()
            let hasRecentVideoPackets = lastPacketTime > 0 && now - lastPacketTime <= Self.freezeTimeout

            if hasRecentVideoPackets {
                return true
            }

            let stalledPresentation = now - lastPresentedProgressTime >= Self.freezeTimeout
            guard stalledPresentation else { return false }

            if keyframeStarved { return true }

            return false
        }

        guard awaitingFirstPresentedFrame, firstPresentedFrameWaitStartTime > 0 else { return false }
        let firstFrameWait = now - firstPresentedFrameWaitStartTime
        return firstFrameWait >= Self.freezeTimeout
    }

    private func maybeLogDeferredDecodeErrorRecovery(now: CFAbsoluteTime) {
        guard now - lastDecodeErrorLogTime >= Self.decodeErrorLogInterval else { return }
        lastDecodeErrorLogTime = now
        MirageLogger.client(
            "Decode error threshold observed for stream \(streamID), deferring recovery until sustained presentation freeze"
        )
    }

    private func trimDecodeRecoveryEscalationWindow(now: CFAbsoluteTime) {
        let oldestAllowed = now - Self.decodeRecoveryEscalationWindow
        decodeRecoveryEscalationTimestamps.removeAll { $0 < oldestAllowed }
    }

    nonisolated static func isStalePostResizeSoftRecoveryRequest(
        capturedEpisodeID: UInt64?,
        currentEpisodeID: UInt64,
        awaitingFirstFrameAfterResize: Bool
    ) -> Bool {
        guard let capturedEpisodeID else { return false }
        return !awaitingFirstFrameAfterResize || currentEpisodeID != capturedEpisodeID
    }

    private func requestSoftRecovery(reason: RecoveryReason) async {
        let now = currentTime()
        let capturedPostResizeRecoveryEpisodeID = awaitingFirstFrameAfterResize ? postResizeRecoveryEpisodeID : nil
        if !Self.shouldDispatchRecovery(
            lastDispatchTime: lastSoftRecoveryRequestTime,
            now: now,
            minimumInterval: Self.softRecoveryMinimumInterval
        ) {
            let lastTime = lastSoftRecoveryRequestTime
            let remainingMs = Int(
                ((Self.softRecoveryMinimumInterval - (now - lastTime)) * 1000)
                    .rounded(.up)
            )
            MirageLogger
                .client(
                    "Soft recovery throttled (\(reason.logLabel), \(max(0, remainingMs))ms remaining) for stream \(streamID)"
                )
            if presentationTier == .activeLive {
                await startKeyframeRecoveryLoopIfNeeded()
            }
            return
        }
        lastSoftRecoveryRequestTime = now

        MirageLogger.client("Starting soft stream recovery (\(reason.logLabel)) for stream \(streamID)")
        if clientRecoveryStatus != .postResizeAwaitingFirstFrame,
           clientRecoveryStatus != .hardRecovery {
            await setClientRecoveryStatus(.keyframeRecovery)
        }
        await clearResizeState()
        let postResizeRecoveryActive = capturedPostResizeRecoveryEpisodeID != nil &&
            !Self.isStalePostResizeSoftRecoveryRequest(
                capturedEpisodeID: capturedPostResizeRecoveryEpisodeID,
                currentEpisodeID: postResizeRecoveryEpisodeID,
                awaitingFirstFrameAfterResize: awaitingFirstFrameAfterResize
            )
        if capturedPostResizeRecoveryEpisodeID != nil, !postResizeRecoveryActive {
            MirageLogger.client(
                "Skipping stale post-resize soft recovery follow-up for stream \(streamID)"
            )
            return
        }
        if postResizeRecoveryActive {
            resetPostResizeRecoveryTracking(clearResizeRecovery: false)
        }
        clearQueuedFramesForRecovery()
        reassembler.trimPendingFramesForRecovery(reason: reason.logLabel)
        reassembler.enterKeyframeOnlyMode()
        if postResizeRecoveryActive {
            await armPostResizeRecoveryWindow(reason: "post-resize-soft-recovery")
        }
        if presentationTier == .activeLive {
            await startKeyframeRecoveryLoopIfNeeded()
        }
        await requestKeyframeRecovery(reason: reason)
    }

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
        let episodeStartedAt = currentTime()
        let episodeDeadline = episodeStartedAt + Self.keyframeRecoveryEpisodeDeadline(
            targetFPS: decodeSchedulerTargetFPS
        )
        defer { keyframeRecoveryTask = nil }

        while !Task.isCancelled {
            guard presentationTier == .activeLive else { return }
            guard reassembler.isAwaitingKeyframe() else { return }

            let now = currentTime()
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
              reassembler.isAwaitingKeyframe(),
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

    private func startFreezeMonitorIfNeeded() {
        guard freezeMonitorTask == nil else { return }
        freezeMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.freezeCheckInterval)
                } catch {
                    break
                }
                await evaluateFreezeState()
            }
            await clearFreezeMonitorTask()
        }
    }

    func stopFreezeMonitor() {
        freezeMonitorTask?.cancel()
        freezeMonitorTask = nil
    }

    private func clearFreezeMonitorTask() {
        freezeMonitorTask = nil
    }

    private func evaluateFreezeState() async {
        // Only recover when genuinely stuck: presentation stalled AND
        // reassembler is stuck awaiting a keyframe that will never arrive
        // (because no P-frames are decoded → no decode errors generated).
        guard hasPresentedFirstFrame,
              presentationTier == .activeLive else { return }
        guard clientRecoveryStatus != .hardRecovery,
              !awaitingFirstPresentedFrame else { return }
        let now = currentTime()
        syncPresentationProgressFromFrameStore(now: now)
        guard lastPresentedProgressTime > 0,
              now - lastPresentedProgressTime >= Self.freezeTimeout else { return }
        guard reassembler.isAwaitingKeyframe() else { return }
        let lastPacketTime = reassembler.latestPacketReceivedTime()
        let packetStarved = lastPacketTime <= 0 || now - lastPacketTime >= Self.freezeTimeout
        MirageLogger.client(
            "Freeze detected for stream \(streamID): presentation stalled " +
            "\(Int((now - lastPresentedProgressTime) * 1000))ms, reassembler awaiting keyframe"
        )
        await maybeTriggerFreezeRecovery(
            now: now,
            keyframeStarved: true,
            packetStarved: packetStarved
        )
    }

    nonisolated static func defaultApplicationForegroundProvider() async -> Bool {
        #if canImport(UIKit)
        return await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        #elseif canImport(AppKit)
        return await MainActor.run {
            NSApp?.isActive ?? true
        }
        #else
        return true
        #endif
    }

    private func isApplicationActiveForFreezeMonitoring() async -> Bool {
        await Self.defaultApplicationForegroundProvider()
    }

    private func maybeTriggerFreezeRecovery(
        now: CFAbsoluteTime,
        keyframeStarved: Bool,
        packetStarved: Bool
    ) async {
        if lastFreezeRecoveryTime > 0,
           now - lastFreezeRecoveryTime < Self.freezeRecoveryCooldown {
            return
        }
        lastFreezeRecoveryTime = now
        consecutiveFreezeRecoveries &+= 1
        Task { @MainActor [weak self] in
            await self?.onStallEvent?()
        }

        switch Self.freezeRecoveryDecision(
            keyframeStarved: keyframeStarved,
            packetStarved: packetStarved,
            consecutiveFreezeRecoveries: consecutiveFreezeRecoveries
        ) {
        case let .monitor(kind):
            let attempt = consecutiveFreezeRecoveries
            consecutiveFreezeRecoveries = 0
            let metricsSnapshot = metricsTracker.snapshot(now: now)
            await maybeLogStreamingAnomalyDiagnostic(
                trigger: "freeze-recovery-\(kind.rawValue)",
                decodedFPS: metricsSnapshot.decodedFPS,
                receivedFPS: metricsSnapshot.receivedFPS
            )
            MirageLogger.client(
                "Presentation stall detected (attempt \(attempt)) for stream \(streamID); " +
                    "\(kind.rawValue), monitoring only"
            )
            return
        case let .hard(kind):
            let attempt = consecutiveFreezeRecoveries
            consecutiveFreezeRecoveries = 0
            let metricsSnapshot = metricsTracker.snapshot(now: now)
            await maybeLogStreamingAnomalyDiagnostic(
                trigger: "freeze-recovery-\(kind.rawValue)",
                decodedFPS: metricsSnapshot.decodedFPS,
                receivedFPS: metricsSnapshot.receivedFPS
            )
            MirageLogger.client(
                "Presentation stall persisted (\(kind.rawValue), attempt \(attempt)) for stream \(streamID); " +
                    "escalating to hard recovery"
            )
            await requestRecovery(reason: .freezeTimeout)
            return
        case let .soft(kind):
            let metricsSnapshot = metricsTracker.snapshot(now: now)
            await maybeLogStreamingAnomalyDiagnostic(
                trigger: "freeze-recovery-\(kind.rawValue)",
                decodedFPS: metricsSnapshot.decodedFPS,
                receivedFPS: metricsSnapshot.receivedFPS
            )
            MirageLogger.client(
                "Presentation stall detected (\(kind.rawValue), attempt \(consecutiveFreezeRecoveries)) for stream \(streamID); " +
                    "requesting bounded recovery"
            )
            await requestSoftRecovery(reason: .freezeTimeout)
        }
    }

    func setResizeState(_ newState: ResizeState) async {
        guard resizeState != newState else { return }
        resizeState = newState

        Task { @MainActor [weak self] in
            guard let self else { return }
            await onResizeStateChanged?(newState)
        }
    }

    func processResizeEvent(
        pixelSize: CGSize,
        screenBounds: CGSize,
        scaleFactor: CGFloat
    )
    async {
        // Calculate aspect ratio
        let aspectRatio = pixelSize.width / pixelSize.height

        // Calculate relative scale
        let drawablePointSize = CGSize(
            width: pixelSize.width / scaleFactor,
            height: pixelSize.height / scaleFactor
        )
        let drawableArea = drawablePointSize.width * drawablePointSize.height
        let screenArea = screenBounds.width * screenBounds.height
        let relativeScale = min(1.0, drawableArea / screenArea)

        // Skip initial layout (prevents decoder P-frame discard mode on first draw)
        let isInitialLayout = lastSentAspectRatio == 0 && lastSentRelativeScale == 0 && lastSentPixelSize == .zero
        if isInitialLayout {
            lastSentAspectRatio = aspectRatio
            lastSentRelativeScale = relativeScale
            lastSentPixelSize = pixelSize
            await setResizeState(.idle)
            return
        }

        // Check if changed significantly
        let aspectChanged = abs(aspectRatio - lastSentAspectRatio) > 0.01
        let scaleChanged = abs(relativeScale - lastSentRelativeScale) > 0.01
        let pixelChanged = pixelSize != lastSentPixelSize
        guard aspectChanged || scaleChanged || pixelChanged else {
            await setResizeState(.idle)
            return
        }

        // Update last sent values
        lastSentAspectRatio = aspectRatio
        lastSentRelativeScale = relativeScale
        lastSentPixelSize = pixelSize

        let event = ResizeEvent(
            aspectRatio: aspectRatio,
            relativeScale: relativeScale,
            clientScreenSize: screenBounds,
            pixelWidth: Int(pixelSize.width.rounded()),
            pixelHeight: Int(pixelSize.height.rounded())
        )

        Task { @MainActor [weak self] in
            await self?.onResizeEvent?(event)
        }

        // Fallback timeout
        do {
            try await Task.sleep(for: Self.resizeTimeout)
            if case .awaiting = resizeState { await setResizeState(.idle) }
        } catch {
            // Cancelled, ignore
        }
    }
}
