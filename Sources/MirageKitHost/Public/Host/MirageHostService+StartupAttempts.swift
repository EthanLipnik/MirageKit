//
//  MirageHostService+StartupAttempts.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/26/26.
//

import Foundation
import MirageKit

#if os(macOS)
extension MirageHostService {
    struct PendingStartupAttempt: Sendable {
        let startupAttemptID: UUID
        let sessionID: UUID
        let clientID: UUID
        let kind: MirageStartupStreamKind
    }

    func registerPendingStartupAttempt(
        streamID: StreamID,
        startupAttemptID: UUID,
        sessionID: UUID,
        clientID: UUID,
        kind: MirageStartupStreamKind
    ) {
        cancelPendingStartupAttempt(streamID: streamID)
        pendingStartupAttemptsByStreamID[streamID] = PendingStartupAttempt(
            startupAttemptID: startupAttemptID,
            sessionID: sessionID,
            clientID: clientID,
            kind: kind
        )
        startupAttemptTimeoutTasksByStreamID[streamID] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: startupAttemptTimeoutSeconds)
            await self.handlePendingStartupAttemptTimeout(streamID: streamID, startupAttemptID: startupAttemptID)
        }
    }

    func cancelPendingStartupAttempt(streamID: StreamID) {
        pendingStartupAttemptsByStreamID.removeValue(forKey: streamID)
        if let task = startupAttemptTimeoutTasksByStreamID.removeValue(forKey: streamID) {
            task.cancel()
        }
    }

    func acknowledgePendingStartupAttempt(
        streamID: StreamID,
        startupAttemptID: UUID,
        kind: MirageStartupStreamKind
    ) async {
        guard let pending = pendingStartupAttemptsByStreamID[streamID] else { return }
        guard pending.startupAttemptID == startupAttemptID, pending.kind == kind else {
            MirageLogger.host(
                "Ignoring stale streamReady ack for stream \(streamID) startupAttemptID=\(startupAttemptID.uuidString)"
            )
            return
        }

        cancelPendingStartupAttempt(streamID: streamID)
        MirageLogger.signpostEvent(.host, "Startup.StreamReadyAckReceived", "stream=\(streamID) kind=\(kind.rawValue)")
        switch kind {
        case .desktop:
            if streamID == desktopStreamID, let desktopContext = desktopStreamContext,
               loomVideoStreamsByStreamID[streamID] != nil {
                await desktopContext.allowEncodingAfterRegistration()
                MirageLogger.host(
                    "Desktop startup ready ack accepted for stream \(streamID); encoding enabled"
                )
            }
        case .window:
            if let context = streamsByID[streamID], loomVideoStreamsByStreamID[streamID] != nil {
                await context.allowEncodingAfterRegistration()
                MirageLogger.host(
                    "Window startup ready ack accepted for stream \(streamID); encoding enabled"
                )
            }
        }
    }

    private func handlePendingStartupAttemptTimeout(
        streamID: StreamID,
        startupAttemptID: UUID
    ) async {
        guard let pending = pendingStartupAttemptsByStreamID[streamID],
              pending.startupAttemptID == startupAttemptID else {
            return
        }
        cancelPendingStartupAttempt(streamID: streamID)

        switch pending.kind {
        case .desktop:
            if let clientContext = findClientContext(sessionID: pending.sessionID),
               clientContext.client.id == pending.clientID {
                let failure = DesktopStreamFailedMessage(
                    reason: "Desktop startup timed out waiting for client readiness acknowledgement.",
                    errorCode: .networkError
                )
                try? await clientContext.send(.desktopStreamFailed, content: failure)
            }
            await stopDesktopStream(reason: .error)
            MirageLogger.host(
                "Desktop startup timed out waiting for client readiness ack stream=\(streamID)"
            )
        case .window:
            if let clientContext = findClientContext(sessionID: pending.sessionID),
               clientContext.client.id == pending.clientID {
                sendControlError(
                    ErrorMessage.ErrorCode.networkError,
                    message: "Stream startup timed out waiting for client readiness acknowledgement.",
                    streamID: streamID,
                    to: clientContext
                )
            }
            if let session = activeSessionByStreamID[streamID] {
                await stopStream(session, minimizeWindow: false)
            }
            MirageLogger.host(
                "Window startup timed out waiting for client readiness ack stream=\(streamID)"
            )
        }
    }
}
#endif
