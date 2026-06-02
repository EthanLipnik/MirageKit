//
//  MirageClientService+StartupReady.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/26/26.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    /// Installs the media security context used by both normal and fast-path media handlers.
    func setMediaSecurityContext(_ context: MirageMediaSecurityContext?) {
        mediaSecurityContext = context
        fastPathState.setMediaSecurityContext(context)
    }

    /// Starts retrying keyframe requests until the fast path observes the startup packet.
    func startStartupRegistrationRetry(streamID: StreamID) {
        startupRegistrationRetryTasks[streamID]?.cancel()
        startupRegistrationRetryTasks[streamID] = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled, attempt < startupRegistrationRetryLimit {
                do {
                    try await Task.sleep(for: startupRegistrationRetryInterval)
                } catch {
                    return
                }
                if !fastPathState.isStartupPacketPending(streamID) { return }
                attempt += 1
                MirageLogger.client(
                    "Startup packet pending for stream \(streamID); requesting keyframe (\(attempt)/\(startupRegistrationRetryLimit))"
                )
                sendKeyframeRequest(for: streamID)
            }
        }
    }

    /// Cancels pending startup registration retries for a stream.
    func cancelStartupRegistrationRetry(streamID: StreamID) {
        if let task = startupRegistrationRetryTasks.removeValue(forKey: streamID) {
            task.cancel()
        }
    }

    func shouldAcceptStartupAttempt(
        _ startupAttemptID: UUID?,
        for streamID: StreamID
    ) -> Bool {
        guard let startupAttemptID else { return true }
        guard let current = startupAttemptIDByStream[streamID] else {
            startupAttemptIDByStream[streamID] = startupAttemptID
            return true
        }
        return current == startupAttemptID
    }

    func registerStartupAttempt(
        _ startupAttemptID: UUID?,
        for streamID: StreamID
    ) {
        guard let startupAttemptID else { return }
        startupAttemptIDByStream[streamID] = startupAttemptID
        beginStreamStartupCriticalSection(streamID: streamID)
    }

    func clearStartupAttempt(for streamID: StreamID) {
        startupAttemptIDByStream.removeValue(forKey: streamID)
        completeStreamStartupCriticalSection(streamID: streamID)
    }

    func sendStreamReadyAck(
        streamID: StreamID,
        startupAttemptID: UUID,
        kind: MirageStartupStreamKind,
        desktopGeometryContract: StreamReadyDesktopGeometryContract? = nil
    ) async {
        do {
            let ready = StreamReadyMessage(
                streamID: streamID,
                startupAttemptID: startupAttemptID,
                kind: kind,
                desktopGeometryContract: desktopGeometryContract
            )
            try await sendControlMessage(.streamReady, content: ready)
            MirageLogger.client(
                "Sent streamReady for stream \(streamID) startupAttemptID=\(startupAttemptID.uuidString) kind=\(kind.rawValue)"
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to send streamReady: ")
        }
    }
}
