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
        kind: MirageStartupStreamKind
    ) async {
        do {
            let ready = StreamReadyMessage(
                streamID: streamID,
                startupAttemptID: startupAttemptID,
                kind: kind
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
