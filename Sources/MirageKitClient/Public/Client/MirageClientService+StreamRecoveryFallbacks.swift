//
//  MirageClientService+StreamRecoveryFallbacks.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
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

@MainActor
extension MirageClientService {
    /// Monitors a foregrounded stream and escalates only after stream and presenter progress stop.
    func startForegroundRecoveryMonitor(
        for streamID: StreamID,
        controller: StreamController,
        trigger: MirageClientStreamRecoveryTrigger
    ) {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishForegroundRecoveryMonitor(for: streamID, token: token) }

            let reassembler = controller.reassembler
            let baselineSubmission = MirageRenderStreamStore.shared
                .submissionSnapshot(for: streamID)
            let startedAt = CFAbsoluteTimeGetCurrent()
            var requestedKeyframe = false
            var lastPresenterRecoveryTime: CFAbsoluteTime = 0

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: foregroundRecoveryMonitorInterval)
                } catch {
                    return
                }

                guard case .connected = connectionState,
                      controllersByStream[streamID] === controller else {
                    return
                }

                let latestSubmission = MirageRenderStreamStore.shared
                    .submissionSnapshot(for: streamID)
                if latestSubmission.hasSubmittedFrame(after: baselineSubmission) {
                    MirageLogger.client(
                        "Recovery presentation resumed for stream \(streamID); ending retry loop trigger=\(trigger.logLabel)"
                    )
                    return
                }

                let now = CFAbsoluteTimeGetCurrent()
                let pendingFrameCount = MirageRenderStreamStore.shared.pendingFrameCount(for: streamID)
                let pendingFrameAgeMs = MirageRenderStreamStore.shared.pendingFrameAgeMs(for: streamID)
                if pendingFrameCount > 0,
                   pendingFrameAgeMs >= 100,
                   now - lastPresenterRecoveryTime >= 1 {
                    lastPresenterRecoveryTime = now
                    let didRequest = MirageRenderStreamStore.shared.requestPresentationRecovery(for: streamID)
                    MirageLogger.client(
                        "Foreground recovery requested presenter recovery for stream \(streamID) " +
                            "pendingFrames=\(pendingFrameCount) pendingAgeMs=\(Int(pendingFrameAgeMs.rounded())) " +
                            "accepted=\(didRequest) trigger=\(trigger.logLabel)"
                    )
                    continue
                }

                reassembler.pollTimeouts()
                let snapshot = reassembler.keyframeWaitSnapshot
                let hardRecoveryFloor = hardRecoveryNoProgressFloor(for: snapshot)
                let noProgressDuration = max(0, now - max(startedAt, snapshot.awaitingSince))
                let keyframeProgressIsFresh = snapshot.latestPendingKeyframeProgress.map { progress in
                    now - progress.lastProgressTime < packetProgressFreshThreshold(for: snapshot)
                } ?? false
                let packetProgressIsFresh = await controller.acceptedPacketFlowCanDeferRecovery(
                    snapshot: snapshot,
                    now: now
                )

                if noProgressDuration >= hardRecoveryFloor {
                    MirageLogger.client(
                        "Foreground recovery escalating to hard recovery for stream \(streamID) " +
                            "noProgressMs=\(Int((noProgressDuration * 1000).rounded())) " +
                            "packetProgressFresh=\(packetProgressIsFresh) " +
                            "rawPackets=\(snapshot.packetAcceptanceSnapshot.rawPacketsReceived) " +
                            "acceptedPackets=\(snapshot.packetAcceptanceSnapshot.acceptedPacketsReceived) " +
                            "keyframeProgressFresh=\(keyframeProgressIsFresh) trigger=\(trigger.logLabel)"
                    )
                    await controller.requestRecovery(
                        reason: .manualRecovery,
                        awaitFirstPresentedFrame: true,
                        firstPresentedFrameWaitReason: trigger.firstPresentedFrameWaitReason
                    )
                    return
                }

                if snapshot.latestPendingKeyframeProgress != nil,
                   keyframeProgressIsFresh {
                    continue
                }
                if Self.shouldContinueForegroundRecoveryForFreshPackets(
                    packetProgressIsFresh: packetProgressIsFresh,
                    noProgressDuration: noProgressDuration,
                    hardRecoveryFloor: hardRecoveryFloor
                ) {
                    continue
                }

                if snapshot.isAwaitingKeyframe,
                   !requestedKeyframe {
                    requestedKeyframe = await controller.requestKeyframeRecovery(reason: .manualRecovery)
                    if requestedKeyframe {
                        MirageLogger.client(
                            "Foreground recovery requested one keyframe for stream \(streamID) after no progress " +
                                "trigger=\(trigger.logLabel)"
                        )
                    }
                    continue
                }
            }
        }

        foregroundRecoveryMonitorTasks[streamID] = (token: token, task: task)
    }

    /// Clears a foreground recovery monitor only if the finishing task still owns the active token.
    func finishForegroundRecoveryMonitor(for streamID: StreamID, token: UUID) {
        guard foregroundRecoveryMonitorTasks[streamID]?.token == token else { return }
        foregroundRecoveryMonitorTasks.removeValue(forKey: streamID)
    }

    private func packetProgressFreshThreshold(for snapshot: FrameReassembler.KeyframeWaitSnapshot) -> CFAbsoluteTime {
        if snapshot.mediaPathProfile.usesAwdlRadioPolicy {
            return 0.25
        }
        return packetProgressFreshThreshold(for: snapshot.transportPathKind)
    }

    private func packetProgressFreshThreshold(for pathKind: MirageCore.MirageNetworkPathKind) -> CFAbsoluteTime {
        switch pathKind {
        case .vpn, .cellular:
            6.0
        case .awdl, .wired, .wifi, .loopback, .other, .unknown:
            2.0
        }
    }

    nonisolated static func shouldContinueForegroundRecoveryForFreshPackets(
        packetProgressIsFresh: Bool,
        noProgressDuration: CFAbsoluteTime,
        hardRecoveryFloor: CFAbsoluteTime
    ) -> Bool {
        packetProgressIsFresh && noProgressDuration < hardRecoveryFloor
    }

    private func hardRecoveryNoProgressFloor(for snapshot: FrameReassembler.KeyframeWaitSnapshot) -> CFAbsoluteTime {
        if snapshot.mediaPathProfile.usesAwdlRadioPolicy {
            return 8.0
        }
        return hardRecoveryNoProgressFloor(for: snapshot.transportPathKind)
    }

    private func hardRecoveryNoProgressFloor(for pathKind: MirageCore.MirageNetworkPathKind) -> CFAbsoluteTime {
        switch pathKind {
        case .vpn, .cellular:
            20.0
        case .awdl, .wired, .wifi, .loopback, .other, .unknown:
            8.0
        }
    }
}
