//
//  StreamController+KeyframeRecoveryGate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/24/26.
//

import Foundation
import MirageKit

extension StreamController {
    func enterKeyframeRecoveryIfNeeded(reason: String) async {
        guard presentationTier == .activeLive else { return }
        if clientRecoveryStatus != .postResizeAwaitingFirstFrame,
           clientRecoveryStatus != .hardRecovery {
            await setClientRecoveryStatus(.keyframeRecovery)
        }
        startFreezeMonitorIfNeeded()
        logRecoveryDecision(.requestKeyframe, reason: reason, snapshot: reassembler.keyframeWaitSnapshot)
    }

    func clearKeyframeRecoveryState() async {
        recoveryCoordinator.recordProgress()
        if clientRecoveryStatus == .keyframeRecovery {
            await setClientRecoveryStatus(.idle)
        }
    }

    func keyframeRequestDecision(
        now: CFAbsoluteTime,
        reason: RecoveryReason,
        snapshot: FrameReassembler.KeyframeWaitSnapshot
    ) -> StreamRecoveryDecision {
        guard reason != .manualRecovery else { return .requestKeyframe }
        guard lastRecoveryRequestDispatchTime > 0 else { return .requestKeyframe }

        if let progress = snapshot.latestPendingKeyframeProgress,
           Self.shouldDeferForPendingKeyframeProgress(
               progress,
               now: now,
               targetFPS: decodeSchedulerTargetFPS
           ) {
            return .deferKeyframeProgress
        }

        let packetProgressThreshold = packetProgressFreshThreshold(for: snapshot.transportPathKind)
        if snapshot.latestPacketReceivedTime > 0,
           now - snapshot.latestPacketReceivedTime < packetProgressThreshold {
            return .deferPacketsFlowing
        }

        let duplicateGrace = duplicateKeyframeRequestGrace(for: snapshot.transportPathKind)
        if now - lastRecoveryRequestDispatchTime < duplicateGrace {
            return .deferPacketsFlowing
        }

        return .requestKeyframe
    }

    func freezeRecoveryDecision(
        now: CFAbsoluteTime,
        snapshot: FrameReassembler.KeyframeWaitSnapshot,
        pendingRenderFrameCount: Int,
        pendingRenderFrameAgeMs: Double
    ) -> StreamRecoveryDecision {
        if pendingRenderFrameCount > 0 {
            return .presenterRecovery
        }

        if let progress = snapshot.latestPendingKeyframeProgress,
           Self.shouldDeferForPendingKeyframeProgress(
               progress,
               now: now,
               targetFPS: decodeSchedulerTargetFPS
           ) {
            return .deferKeyframeProgress
        }

        let packetProgressThreshold = packetProgressFreshThreshold(for: snapshot.transportPathKind)
        if snapshot.latestPacketReceivedTime > 0,
           now - snapshot.latestPacketReceivedTime < packetProgressThreshold {
            return .deferPacketsFlowing
        }

        let hardFloor = hardRecoveryNoProgressFloor(for: snapshot.transportPathKind)
        if snapshot.awaitingDuration >= hardFloor {
            return .hardRecovery
        }

        return .requestKeyframe
    }

    func logRecoveryDecision(
        _ decision: StreamRecoveryDecision,
        reason: String,
        snapshot: FrameReassembler.KeyframeWaitSnapshot,
        pendingRenderFrameCount: Int? = nil,
        pendingRenderFrameAgeMs: Double? = nil
    ) {
        let now = currentTime
        let packetAgeMs = snapshot.latestPacketReceivedTime > 0
            ? Int(max(0, now - snapshot.latestPacketReceivedTime) * 1000)
            : -1
        let awaitingMs = Int(snapshot.awaitingDuration * 1000)
        let progressText: String
        if let progress = snapshot.latestPendingKeyframeProgress {
            let percent = Int((progress.progressRatio * 100).rounded())
            let progressAgeMs = Int(max(0, now - progress.lastProgressTime) * 1000)
            progressText = "\(percent)% ageMs=\(progressAgeMs) frame=\(progress.frameNumber)"
        } else {
            progressText = "none"
        }
        let renderText: String
        if let pendingRenderFrameCount, let pendingRenderFrameAgeMs {
            renderText = " pendingRenderFrames=\(pendingRenderFrameCount) pendingRenderAgeMs=\(Int(pendingRenderFrameAgeMs.rounded()))"
        } else {
            renderText = ""
        }
        MirageLogger.client(
            "Recovery decision \(decision.rawValue) for stream \(streamID) reason=\(reason) " +
                "path=\(snapshot.transportPathKind.rawValue) awaiting=\(snapshot.isAwaitingKeyframe) " +
                "awaitingMs=\(awaitingMs) packetAgeMs=\(packetAgeMs) keyframeProgress=\(progressText)" +
                renderText
        )
    }

    func duplicateKeyframeRequestGrace(for pathKind: MirageNetworkPathKind) -> CFAbsoluteTime {
        switch pathKind {
        case .vpn, .cellular:
            Self.remoteDuplicateKeyframeRequestGrace
        case .awdl, .wifi, .wired, .loopback, .other, .unknown:
            Self.localDuplicateKeyframeRequestGrace
        }
    }

    func hardRecoveryNoProgressFloor(for pathKind: MirageNetworkPathKind) -> CFAbsoluteTime {
        switch pathKind {
        case .vpn, .cellular:
            Self.remoteHardRecoveryNoProgressFloor
        case .awdl, .wifi, .wired, .loopback, .other, .unknown:
            Self.localHardRecoveryNoProgressFloor
        }
    }

    func packetProgressFreshThreshold(for pathKind: MirageNetworkPathKind) -> CFAbsoluteTime {
        switch pathKind {
        case .vpn, .cellular:
            Self.remotePacketProgressFreshThreshold
        case .awdl, .wifi, .wired, .loopback, .other, .unknown:
            Self.localPacketProgressFreshThreshold
        }
    }
}
