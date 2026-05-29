//
//  StreamController+FreezeMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

extension StreamController {
    func startFreezeMonitorIfNeeded() {
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

    func clearFreezeMonitorTask() {
        freezeMonitorTask = nil
    }

    func evaluateFreezeState() async {
        // Only recover when genuinely stuck: presentation stalled AND
        // reassembler is stuck awaiting a keyframe that will never arrive
        // (because no P-frames are decoded → no decode errors generated).
        guard hasPresentedFirstFrame,
              presentationTier == .activeLive else { return }
        guard clientRecoveryStatus != .hardRecovery,
              !awaitingFirstPresentedFrame else { return }
        let now = currentTime
        _ = syncPresentationProgressFromFrameStore(now: now)
        guard lastPresentedProgressTime > 0,
              now - lastPresentedProgressTime >= Self.freezeTimeout else { return }

        let pendingFrameCount = MirageRenderStreamStore.shared.pendingFrameCount(for: streamID)
        reassembler.pollTimeouts()
        if reassembler.isAwaitingKeyframe {
            let pendingFrameAgeMs = MirageRenderStreamStore.shared.pendingFrameAgeMs(for: streamID)
            let snapshot = reassembler.keyframeWaitSnapshot
            let decision = freezeRecoveryDecision(
                now: now,
                snapshot: snapshot,
                pendingRenderFrameCount: pendingFrameCount,
                pendingRenderFrameAgeMs: pendingFrameAgeMs
            )
            logRecoveryDecision(
                decision,
                reason: "freeze-monitor-awaiting-keyframe",
                snapshot: snapshot,
                pendingRenderFrameCount: pendingFrameCount,
                pendingRenderFrameAgeMs: pendingFrameAgeMs
            )
            switch decision {
            case .presenterRecovery:
                _ = await maybeTriggerRenderSubmissionRecovery(
                    now: now,
                    pendingFrameCount: pendingFrameCount
                )
                return
            case .deferPacketsFlowing,
                 .deferKeyframeProgress,
                 .deferRetryGrace:
                return
            case .requestKeyframe:
                if pendingFrameCount > 0,
                   pendingFrameAgeMs >= Self.stalePendingRenderFrameRecoveryAgeMs {
                    let droppedPendingFrames = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
                    if droppedPendingFrames > 0 {
                        MirageLogger.client(
                            "Dropped \(droppedPendingFrames) stale pending render frame(s) before keyframe-starved " +
                                "freeze recovery for stream \(streamID)"
                        )
                    }
                }
                await enterKeyframeRecoveryIfNeeded(reason: "freeze-monitor", cause: .freezeTimeout)
                if await requestKeyframeRecovery(reason: .freezeTimeout) {
                    lastFreezeRecoveryTime = now
                }
                return
            case .hardRecovery:
                let metricsSnapshot = metricsTracker.snapshot(now: now)
                await maybeLogStreamingAnomalyDiagnostic(
                    trigger: "freeze-recovery-hard-recovery",
                    decodedFPS: metricsSnapshot.decodedFPS,
                    receivedFPS: metricsSnapshot.receivedFPS
                )
                MirageLogger.client(
                    "Presentation stall persisted without packet/keyframe progress for stream \(streamID); escalating to hard recovery"
                )
                await requestRecovery(reason: .freezeTimeout)
                return
            }
        }

        let pendingFrameAgeMs = MirageRenderStreamStore.shared.pendingFrameAgeMs(for: streamID)
        if await maybeRecoverNonAwaitingKeyframeFreeze(
            now: now,
            pendingFrameCount: pendingFrameCount,
            pendingFrameAgeMs: pendingFrameAgeMs
        ) {
            return
        }

        guard reassembler.isAwaitingKeyframe else { return }
        let lastPacketTime = reassembler.latestPacketReceivedTime
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

    func maybeRecoverNonAwaitingKeyframeFreeze(
        now: CFAbsoluteTime,
        pendingFrameCount: Int,
        pendingFrameAgeMs: Double
    ) async -> Bool {
        if freezeRecoveryEpisodeHasPresentationProgress() {
            clearFreezeRecoveryEpisode(reason: "presentation-progress")
            return true
        }

        let metricsSnapshot = metricsTracker.snapshot(now: now)
        let noMediaProgress = metricsSnapshot.receivedFPS <= 0.5 && metricsSnapshot.decodedFPS <= 0.5
        let stalePendingFrame = pendingFrameCount > 0 &&
            pendingFrameAgeMs >= Self.stalePendingRenderFrameRecoveryAgeMs
        let transportFreezeEvidence = hasTransportFreezeEvidence(now: now)

        if pendingFrameCount > 0,
           !stalePendingFrame,
           freezeRecoveryEpisode?.presenterProbeAttempted != true,
           await maybeTriggerRenderSubmissionRecovery(now: now, pendingFrameCount: pendingFrameCount) {
            armFreezePresenterProbe(now: now)
            return true
        }

        if noMediaProgress, transportFreezeEvidence {
            await requestFreezeKeyframeRecovery(
                now: now,
                reason: "no-media-progress",
                pendingFrameCount: pendingFrameCount,
                pendingFrameAgeMs: pendingFrameAgeMs
            )
            return true
        }

        if noMediaProgress, !stalePendingFrame {
            if hostMediaAppearsDynamicallyIdle(now: now) {
                await maybeLogStreamingAnomalyDiagnostic(
                    trigger: "freeze-recovery-dynamic-sck-idle",
                    decodedFPS: metricsSnapshot.decodedFPS,
                    receivedFPS: metricsSnapshot.receivedFPS
                )
                MirageLogger.client(
                    "Presentation stall has no media progress for stream \(streamID), but host capture appears idle; " +
                        "preserving dynamic SCK idle state"
                )
                return true
            }
            if freezeRecoveryEpisode == nil {
                armFreezePresenterProbe(now: now)
                await maybeLogStreamingAnomalyDiagnostic(
                    trigger: "freeze-recovery-no-media-probe",
                    decodedFPS: metricsSnapshot.decodedFPS,
                    receivedFPS: metricsSnapshot.receivedFPS
                )
                MirageLogger.client(
                    "Presentation stall has no media progress for stream \(streamID) while host media is active; " +
                        "arming bounded recovery probe"
                )
                return true
            }
            if let episode = freezeRecoveryEpisode,
               episode.state == .presenterProbe,
               now - episode.lastActionTime >= Self.freezePresenterProbeGrace {
                await requestFreezeKeyframeRecovery(
                    now: now,
                    reason: "no-media-progress-with-active-host",
                    pendingFrameCount: pendingFrameCount,
                    pendingFrameAgeMs: pendingFrameAgeMs
                )
                return true
            }
            await maybeLogStreamingAnomalyDiagnostic(
                trigger: "freeze-recovery-no-media-without-transport-evidence",
                decodedFPS: metricsSnapshot.decodedFPS,
                receivedFPS: metricsSnapshot.receivedFPS
            )
            MirageLogger.client(
                "Presentation stall has no media progress for stream \(streamID), but no transport failure evidence; " +
                    "preserving decode chain"
            )
            return true
        }

        if stalePendingFrame {
            let droppedPendingFrames = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
            lastFreezeRecoveryTime = now
            consecutiveFreezeRecoveries &+= 1
            Task { @MainActor [weak self] in
                await self?.onStallEvent?(.presentationRecovery)
            }
            await maybeLogStreamingAnomalyDiagnostic(
                trigger: "freeze-recovery-stale-presentation-only",
                decodedFPS: metricsSnapshot.decodedFPS,
                receivedFPS: metricsSnapshot.receivedFPS
            )
            MirageLogger.client(
                "Dropped \(droppedPendingFrames) stale pending render frame(s) during presentation-only " +
                    "freeze recovery for stream \(streamID); preserving decode chain"
            )
            return true
        }

        if let episode = freezeRecoveryEpisode,
           episode.state == .presenterProbe,
           now - episode.lastActionTime >= Self.freezePresenterProbeGrace {
            guard transportFreezeEvidence else {
                await maybeLogStreamingAnomalyDiagnostic(
                    trigger: "freeze-recovery-presenter-probe-timeout-without-transport-evidence",
                    decodedFPS: metricsSnapshot.decodedFPS,
                    receivedFPS: metricsSnapshot.receivedFPS
                )
                MirageLogger.client(
                    "Freeze presenter probe timed out for stream \(streamID), but transport is not implicated; " +
                        "preserving decode chain"
                )
                return true
            }
            await requestFreezeKeyframeRecovery(
                now: now,
                reason: "presenter-probe-timeout",
                pendingFrameCount: pendingFrameCount,
                pendingFrameAgeMs: pendingFrameAgeMs
            )
            return true
        }

        return false
    }

    func hostMediaAppearsDynamicallyIdle(now: CFAbsoluteTime) -> Bool {
        guard let hostMetrics = latestHostMetricsMessage,
              latestHostMetricsTime > 0,
              now - latestHostMetricsTime <= max(2.0, Self.freezeTimeout * 2.0) else {
            return false
        }
        let captureIngressFPS = hostMetrics.captureIngressFPS ?? 0
        let captureFPS = hostMetrics.captureFPS ?? 0
        let encodeAttemptFPS = hostMetrics.encodeAttemptFPS ?? 0
        return hostMetrics.encodedFPS <= 0.5 &&
            hostMetrics.idleEncodedFPS <= 0.5 &&
            captureIngressFPS <= 0.5 &&
            captureFPS <= 0.5 &&
            encodeAttemptFPS <= 0.5
    }

    func hasTransportFreezeEvidence(now: CFAbsoluteTime) -> Bool {
        let reassemblerMetrics = reassembler.snapshotMetrics
        let hasReassemblyLoss = reassemblerMetrics.forwardGapTimeouts > 0 ||
            reassemblerMetrics.missingFragmentTimeouts > 0 ||
            reassemblerMetrics.incompleteFrameTimeouts > 0 ||
            reassemblerMetrics.incompleteFrameNoProgressTimeouts > 0 ||
            reassemblerMetrics.incompleteFrameLifetimeTimeouts > 0
        if hasReassemblyLoss { return true }

        let latestPacketTime = reassembler.latestPacketReceivedTime
        guard latestPacketTime > 0,
              now - latestPacketTime >= Self.freezeTimeout,
              let hostMetrics = latestHostMetricsMessage,
              latestHostMetricsTime > 0,
              now - latestHostMetricsTime <= max(2.0, Self.freezeTimeout * 2.0) else {
            return false
        }

        let targetFPS = Double(max(1, hostMetrics.targetFrameRate))
        let frameBudgetMs = 1_000.0 / targetFPS
        let currentBitrate = hostMetrics.currentBitrate ??
            hostMetrics.realtimeBitrateCeiling ??
            hostMetrics.encoderRequestedBitrateBps ??
            hostMetrics.requestedTargetBitrate ??
            0
        let estimatedFrameBytes = currentBitrate > 0
            ? currentBitrate / 8 / max(1, hostMetrics.targetFrameRate)
            : 0
        let queuePressureBytes = max(128 * 1024, estimatedFrameBytes * 4)
        let hasTransportDrops = (hostMetrics.senderLocalDeadlineDrops ?? 0) > 0 ||
            (hostMetrics.stalePacketDrops ?? 0) > 0 ||
            (hostMetrics.generationAbortDrops ?? 0) > 0 ||
            (hostMetrics.nonKeyframeHoldDrops ?? 0) > 0
        let hasSevereSendLatency = (hostMetrics.nonKeyframeSendCompletionMaxMs ?? 0) >= max(120.0, frameBudgetMs * 6.0) ||
            (hostMetrics.sendCompletionMaxMs ?? 0) >= max(160.0, frameBudgetMs * 8.0)
        let hasQueueBacklog = (hostMetrics.sendQueueBytes ?? 0) >= queuePressureBytes
        return hasTransportDrops || hasSevereSendLatency || hasQueueBacklog
    }

    func armFreezePresenterProbe(now: CFAbsoluteTime) {
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        freezeRecoveryEpisodeID &+= 1
        freezeRecoveryEpisode = FreezeRecoveryEpisode(
            id: freezeRecoveryEpisodeID,
            state: .presenterProbe,
            startedAt: now,
            baselineSubmittedSequence: snapshot.sequence,
            lastActionTime: now,
            presenterProbeAttempted: true,
            keyframeRequestAttempts: 0
        )
        MirageLogger.client(
            "Freeze recovery presenter probe armed for stream \(streamID) " +
                "episode=\(freezeRecoveryEpisodeID) baselineSubmitted=\(snapshot.sequence)"
        )
    }

    func requestFreezeKeyframeRecovery(
        now: CFAbsoluteTime,
        reason: String,
        pendingFrameCount: Int,
        pendingFrameAgeMs: Double
    ) async {
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        if freezeRecoveryEpisode == nil {
            freezeRecoveryEpisodeID &+= 1
            freezeRecoveryEpisode = FreezeRecoveryEpisode(
                id: freezeRecoveryEpisodeID,
                state: .requestingKeyframe,
                startedAt: now,
                baselineSubmittedSequence: snapshot.sequence,
                lastActionTime: now,
                presenterProbeAttempted: false,
                keyframeRequestAttempts: 0
            )
        }
        freezeRecoveryEpisode?.state = .requestingKeyframe
        freezeRecoveryEpisode?.lastActionTime = now
        freezeRecoveryEpisode?.keyframeRequestAttempts += 1

        if pendingFrameCount > 0,
           pendingFrameAgeMs >= Self.stalePendingRenderFrameRecoveryAgeMs {
            let droppedPendingFrames = MirageRenderStreamStore.shared.clearPendingFrames(for: streamID)
            if droppedPendingFrames > 0 {
                MirageLogger.client(
                    "Dropped \(droppedPendingFrames) stale pending render frame(s) before freeze keyframe recovery " +
                        "for stream \(streamID)"
                )
            }
        }
        reassembler.beginKeyframeWait()
        discardQueuedFramesForRecovery()
        await enterKeyframeRecoveryIfNeeded(reason: "freeze-monitor-\(reason)", cause: .freezeTimeout)
        let didRequest = await requestKeyframeRecovery(reason: .freezeTimeout, bypassRetryGate: true)
        if didRequest {
            lastFreezeRecoveryTime = now
            freezeRecoveryEpisode?.state = .awaitingKeyframePresentation
        } else if freezeRecoveryEpisode?.keyframeRequestAttempts ?? 0 >= Self.freezeRecoveryEscalationThreshold {
            freezeRecoveryEpisode?.state = .hardRecovery
            MirageLogger.client(
                "Freeze keyframe recovery could not dispatch after bounded attempts for stream \(streamID); " +
                    "escalating to hard recovery"
            )
            await requestRecovery(reason: .freezeTimeout)
        }
    }

    func freezeRecoveryEpisodeHasPresentationProgress() -> Bool {
        guard let episode = freezeRecoveryEpisode else { return false }
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        return snapshot.sequence > episode.baselineSubmittedSequence
    }

    func clearFreezeRecoveryEpisode(reason: String) {
        guard let episode = freezeRecoveryEpisode else { return }
        MirageLogger.client(
            "Freeze recovery episode \(episode.id) cleared for stream \(streamID): \(reason)"
        )
        freezeRecoveryEpisode = nil
        consecutiveFreezeRecoveries = 0
    }

    func maybeTriggerRenderSubmissionRecovery(
        now: CFAbsoluteTime,
        pendingFrameCount: Int
    ) async -> Bool {
        let metricsSnapshot = metricsTracker.snapshot(now: now)
        let decodeIsBehind = metricsSnapshot.receivedFPS > 0 &&
            metricsSnapshot.decodedFPS < max(1.0, metricsSnapshot.receivedFPS * 0.5)
        guard !decodeIsBehind else {
            await maybeLogStreamingAnomalyDiagnostic(
                trigger: "freeze-recovery-decode-bound-render-pending",
                decodedFPS: metricsSnapshot.decodedFPS,
                receivedFPS: metricsSnapshot.receivedFPS
            )
            MirageLogger.client(
                "Presentation recovery skipped for stream \(streamID) because decode is not keeping up " +
                    "(pendingFrames=\(pendingFrameCount), decoded=\(metricsSnapshot.decodedFPS), received=\(metricsSnapshot.receivedFPS))"
            )
            return true
        }

        if lastFreezeRecoveryTime > 0,
           now - lastFreezeRecoveryTime < Self.freezeRecoveryCooldown {
            return true
        }

        lastFreezeRecoveryTime = now
        consecutiveFreezeRecoveries &+= 1
        Task { @MainActor [weak self] in
            await self?.onStallEvent?(.presentationRecovery)
        }

        await maybeLogStreamingAnomalyDiagnostic(
            trigger: "freeze-recovery-render-submission",
            decodedFPS: metricsSnapshot.decodedFPS,
            receivedFPS: metricsSnapshot.receivedFPS
        )

        let didRequestPresenterRecovery = MirageRenderStreamStore.shared.requestPresentationRecovery(for: streamID)
        if didRequestPresenterRecovery {
            MirageLogger.client(
                "Presentation stall detected with pending render frames for stream \(streamID); " +
                    "requested presenter recovery (pendingFrames=\(pendingFrameCount), attempt=\(consecutiveFreezeRecoveries))"
            )
            return true
        }

        MirageLogger.client(
            "Presentation stall detected with pending render frames for stream \(streamID), " +
                "but no presenter recovery handler was active (pendingFrames=\(pendingFrameCount))"
        )
        return false
    }

    func maybeTriggerFreezeRecovery(
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
        let stallEvent: RuntimeWorkloadSafetyStallEvent = packetStarved ? .packetStarved : .keyframeStarved
        Task { @MainActor [weak self] in
            await self?.onStallEvent?(stallEvent)
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
}
