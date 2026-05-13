//
//  MirageClientService+StreamRecoveryFallbacks.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    /// Starts a bounded retry loop while recovery is waiting for a presented frame.
    func startRecoveryKeyframeRetry(
        for streamID: StreamID,
        controller: StreamController,
        trigger: MirageClientStreamRecoveryTrigger
    ) {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishRecoveryKeyframeRetry(for: streamID, token: token) }

            let reassembler = controller.reassembler
            let baselineSubmittedSequence = MirageRenderStreamStore.shared
                .submissionSnapshot(for: streamID)
                .sequence
            var lastPacketTime = reassembler.latestPacketReceivedTime

            for attempt in 1 ... recoveryKeyframeRetryLimit {
                do {
                    try await Task.sleep(for: recoveryKeyframeRetryInterval)
                } catch {
                    return
                }

                guard case .connected = connectionState,
                      controllersByStream[streamID] != nil else {
                    return
                }

                let latestPacketTime = reassembler.latestPacketReceivedTime
                let latestSubmittedSequence = MirageRenderStreamStore.shared
                    .submissionSnapshot(for: streamID)
                    .sequence
                if latestSubmittedSequence > baselineSubmittedSequence {
                    MirageLogger.client(
                        "Recovery presentation resumed for stream \(streamID); ending retry loop trigger=\(trigger.logLabel)"
                    )
                    return
                }

                let awaitingKeyframe = reassembler.isAwaitingKeyframe
                if latestPacketTime <= lastPacketTime {
                    let keyframeText =
                        awaitingKeyframe ? "awaiting-keyframe" : "awaiting-presentation"
                    MirageLogger.client(
                        "Recovery not yet presented for stream \(streamID); waiting for packet flow before retrying keyframe "
                            + "(attempt \(attempt)/\(recoveryKeyframeRetryLimit), state=\(keyframeText)) "
                            + "trigger=\(trigger.logLabel)"
                    )
                    lastPacketTime = latestPacketTime
                    continue
                }

                let keyframeText =
                    awaitingKeyframe ? "awaiting-keyframe" : "awaiting-presentation"
                MirageLogger.client(
                    "Recovery not yet presented for stream \(streamID); retrying keyframe "
                        + "(\(attempt)/\(recoveryKeyframeRetryLimit), packets=flowing, state=\(keyframeText)) "
                        + "trigger=\(trigger.logLabel)"
                )

                sendKeyframeRequest(for: streamID)
                lastPacketTime = latestPacketTime
            }
        }

        recoveryKeyframeRetryTasks[streamID] = (token: token, task: task)
    }

    /// Clears a retry loop only if the finishing task still owns the active token.
    func finishRecoveryKeyframeRetry(for streamID: StreamID, token: UUID) {
        guard recoveryKeyframeRetryTasks[streamID]?.token == token else { return }
        recoveryKeyframeRetryTasks.removeValue(forKey: streamID)
    }
}
