//
//  StreamController+KeyframeRecoveryGate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/24/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

extension StreamController {
    func enterKeyframeRecoveryIfNeeded(
        reason: String,
        cause: MirageStreamClientRecoveryCause = .frameLoss
    ) async {
        guard presentationTier == .activeLive else { return }
        if clientRecoveryStatus != .postResizeAwaitingFirstFrame,
           clientRecoveryStatus != .hardRecovery {
            await setClientRecoveryStatus(.keyframeRecovery, cause: cause)
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

        if let progress = snapshot.latestPendingKeyframeProgress,
           Self.shouldDeferForPendingKeyframeProgress(
               progress,
               now: now,
               targetFPS: decodeSchedulerTargetFPS
           ) {
            return .deferKeyframeProgress
        }

        guard lastRecoveryRequestDispatchTime > 0 else { return .requestKeyframe }

        if acceptedPacketFlowCanDeferRecovery(snapshot: snapshot, now: now) {
            return .deferPacketsFlowing
        }

        let duplicateGrace = keyframeRetryGrace(for: snapshot)
        if now - lastRecoveryRequestDispatchTime < duplicateGrace {
            return .deferRetryGrace
        }

        return .requestKeyframe
    }

    func freezeRecoveryDecision(
        now: CFAbsoluteTime,
        snapshot: FrameReassembler.KeyframeWaitSnapshot,
        pendingRenderFrameCount: Int,
        pendingRenderFrameAgeMs: Double
    ) -> StreamRecoveryDecision {
        if pendingRenderFrameCount > 0,
           pendingRenderFrameAgeMs < Self.stalePendingRenderFrameRecoveryAgeMs {
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

        if acceptedPacketFlowCanDeferRecovery(snapshot: snapshot, now: now) {
            return .deferPacketsFlowing
        }

        let hardFloor = hardRecoveryNoProgressFloor(for: snapshot)
        if snapshot.awaitingDuration(now: now) >= hardFloor {
            return .hardRecovery
        }

        if snapshot.isAwaitingKeyframe,
           clientRecoveryStatus == .keyframeRecovery,
           lastRecoveryRequestDispatchTime > 0 {
            let duplicateGrace = keyframeRetryGrace(for: snapshot)
            if now - lastRecoveryRequestDispatchTime >= duplicateGrace {
                return .requestKeyframe
            }
            return .deferRetryGrace
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
        let acceptedPacketAgeMs = snapshot.latestAcceptedPacketReceivedTime > 0
            ? Int(max(0, now - snapshot.latestAcceptedPacketReceivedTime) * 1000)
            : -1
        let awaitingMs = Int(snapshot.awaitingDuration(now: now) * 1000)
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
                "path=\(snapshot.transportPathKind.rawValue) media=\(snapshot.mediaPathProfile.rawValue) " +
                "awaiting=\(snapshot.isAwaitingKeyframe) " +
                "awaitingMs=\(awaitingMs) packetAgeMs=\(packetAgeMs) " +
                "acceptedPacketAgeMs=\(acceptedPacketAgeMs) " +
                "rawPackets=\(snapshot.packetAcceptanceSnapshot.rawPacketsReceived) " +
                "acceptedPackets=\(snapshot.packetAcceptanceSnapshot.acceptedPacketsReceived) " +
                "keyframeProgress=\(progressText)" +
                renderText
        )
    }

    func acceptedPacketFlowCanDeferRecovery(
        snapshot: FrameReassembler.KeyframeWaitSnapshot,
        now: CFAbsoluteTime
    ) -> Bool {
        let threshold = packetProgressFreshThreshold(for: snapshot)
        guard !snapshot.isAwaitingKeyframe,
              snapshot.latestAcceptedPacketReceivedTime > 0,
              now - snapshot.latestAcceptedPacketReceivedTime < threshold else {
            return false
        }
        guard usesAwdlRecoveryProgressGate(snapshot: snapshot),
              presentationTier == .activeLive else {
            return true
        }

        let latestUsefulProgressTime = max(lastDecodedProgressTime, lastPresentedProgressTime)
        return latestUsefulProgressTime > lastRecoveryRequestDispatchTime &&
            now - latestUsefulProgressTime < threshold
    }

    private func usesAwdlRecoveryProgressGate(
        snapshot: FrameReassembler.KeyframeWaitSnapshot
    ) -> Bool {
        snapshot.transportPathKind == .awdl || snapshot.mediaPathProfile.usesAwdlRadioPolicy
    }

    func duplicateKeyframeRequestGrace(for snapshot: FrameReassembler.KeyframeWaitSnapshot) -> CFAbsoluteTime {
        duplicateKeyframeRequestGrace(for: snapshot.mediaPathProfile, pathKind: snapshot.transportPathKind)
    }

    func keyframeRetryGrace(for snapshot: FrameReassembler.KeyframeWaitSnapshot) -> CFAbsoluteTime {
        if snapshot.isAwaitingKeyframe, snapshot.latestPendingKeyframeProgress == nil {
            return awaitingKeyframeNoProgressRetryGrace(for: snapshot)
        }
        return duplicateKeyframeRequestGrace(for: snapshot)
    }

    func duplicateKeyframeRequestGrace(for pathKind: MirageCore.MirageNetworkPathKind) -> CFAbsoluteTime {
        duplicateKeyframeRequestGrace(
            for: MirageMedia.MirageMediaPathProfile.classify(pathKind: pathKind, interfaceNames: []),
            pathKind: pathKind
        )
    }

    func duplicateKeyframeRequestGrace(
        for mediaProfile: MirageMedia.MirageMediaPathProfile,
        pathKind: MirageCore.MirageNetworkPathKind
    ) -> CFAbsoluteTime {
        if mediaProfile.usesAwdlRadioPolicy {
            return Self.localDuplicateKeyframeRequestGrace
        }
        switch pathKind {
        case .vpn, .cellular:
            return Self.remoteDuplicateKeyframeRequestGrace
        case .awdl, .wifi, .wired, .loopback, .other, .unknown:
            return Self.localDuplicateKeyframeRequestGrace
        }
    }

    func awaitingKeyframeNoProgressRetryGrace(
        for snapshot: FrameReassembler.KeyframeWaitSnapshot
    ) -> CFAbsoluteTime {
        awaitingKeyframeNoProgressRetryGrace(
            for: snapshot.mediaPathProfile,
            pathKind: snapshot.transportPathKind
        )
    }

    func awaitingKeyframeNoProgressRetryGrace(
        for mediaProfile: MirageMedia.MirageMediaPathProfile,
        pathKind: MirageCore.MirageNetworkPathKind
    ) -> CFAbsoluteTime {
        if mediaProfile.usesAwdlRadioPolicy {
            return Self.localAwaitingKeyframeNoProgressRetryGrace
        }
        switch pathKind {
        case .vpn, .cellular:
            return Self.remoteAwaitingKeyframeNoProgressRetryGrace
        case .awdl, .wifi, .wired, .loopback, .other, .unknown:
            return Self.localAwaitingKeyframeNoProgressRetryGrace
        }
    }

    func hardRecoveryNoProgressFloor(for snapshot: FrameReassembler.KeyframeWaitSnapshot) -> CFAbsoluteTime {
        hardRecoveryNoProgressFloor(for: snapshot.mediaPathProfile, pathKind: snapshot.transportPathKind)
    }

    func hardRecoveryNoProgressFloor(for pathKind: MirageCore.MirageNetworkPathKind) -> CFAbsoluteTime {
        hardRecoveryNoProgressFloor(
            for: MirageMedia.MirageMediaPathProfile.classify(pathKind: pathKind, interfaceNames: []),
            pathKind: pathKind
        )
    }

    func hardRecoveryNoProgressFloor(
        for mediaProfile: MirageMedia.MirageMediaPathProfile,
        pathKind: MirageCore.MirageNetworkPathKind
    ) -> CFAbsoluteTime {
        if mediaProfile.usesAwdlRadioPolicy {
            return Self.localHardRecoveryNoProgressFloor
        }
        switch pathKind {
        case .vpn, .cellular:
            return Self.remoteHardRecoveryNoProgressFloor
        case .awdl, .wifi, .wired, .loopback, .other, .unknown:
            return Self.localHardRecoveryNoProgressFloor
        }
    }

    func packetProgressFreshThreshold(for snapshot: FrameReassembler.KeyframeWaitSnapshot) -> CFAbsoluteTime {
        packetProgressFreshThreshold(for: snapshot.mediaPathProfile, pathKind: snapshot.transportPathKind)
    }

    func packetProgressFreshThreshold(for pathKind: MirageCore.MirageNetworkPathKind) -> CFAbsoluteTime {
        packetProgressFreshThreshold(
            for: MirageMedia.MirageMediaPathProfile.classify(pathKind: pathKind, interfaceNames: []),
            pathKind: pathKind
        )
    }

    func packetProgressFreshThreshold(
        for mediaProfile: MirageMedia.MirageMediaPathProfile,
        pathKind: MirageCore.MirageNetworkPathKind
    ) -> CFAbsoluteTime {
        if mediaProfile.usesAwdlRadioPolicy {
            return 0.25
        }
        switch pathKind {
        case .vpn, .cellular:
            return Self.remotePacketProgressFreshThreshold
        case .awdl, .wifi, .wired, .loopback, .other, .unknown:
            return Self.localPacketProgressFreshThreshold
        }
    }
}
