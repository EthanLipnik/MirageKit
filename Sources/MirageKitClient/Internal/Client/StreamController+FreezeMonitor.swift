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
        if pendingFrameCount > 0,
           await maybeTriggerRenderSubmissionRecovery(
               now: now,
               pendingFrameCount: pendingFrameCount
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

    func maybeTriggerRenderSubmissionRecovery(
        now: CFAbsoluteTime,
        pendingFrameCount: Int
    ) async -> Bool {
        if lastFreezeRecoveryTime > 0,
           now - lastFreezeRecoveryTime < Self.freezeRecoveryCooldown {
            return true
        }

        lastFreezeRecoveryTime = now
        consecutiveFreezeRecoveries &+= 1
        Task { @MainActor [weak self] in
            await self?.onStallEvent?(.presentationRecovery)
        }

        let metricsSnapshot = metricsTracker.snapshot(now: now)
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
