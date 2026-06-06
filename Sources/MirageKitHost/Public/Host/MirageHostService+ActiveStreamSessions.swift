//
//  MirageHostService+ActiveStreamSessions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Active stream session indexes.
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
#if os(macOS)
@MainActor
extension MirageHostService {
    /// Notifies the delegate after the active stream collection gains or loses a stream.
    func notifyActiveStreamActivityChanged() {
        updateCursorMonitoringForActiveStreams()
        delegate?.activeStreamsDidChange()
    }

    /// Registers an active stream session and updates window-to-stream indexes.
    func registerActiveStreamSession(_ session: MirageStreamSession) {
        let wasActive = activeSessionByStreamID[session.id] != nil

        if let previousSession = activeSessionByStreamID[session.id],
           previousSession.window.id != session.window.id,
           activeStreamIDByWindowID[previousSession.window.id] == session.id {
            activeStreamIDByWindowID.removeValue(forKey: previousSession.window.id)
        }

        activeSessionByStreamID[session.id] = session
        activeWindowIDByStreamID[session.id] = session.window.id
        activeStreamIDByWindowID[session.window.id] = session.id

        if let index = activeStreams.firstIndex(where: { $0.id == session.id }) {
            activeStreams[index] = session
        } else {
            activeStreams.append(session)
        }

        syncSharedClipboardState()
        if !wasActive {
            notifyActiveStreamActivityChanged()
        }
    }

    /// Removes an active stream session and clears derived window indexes.
    func removeActiveStreamSession(streamID: StreamID) {
        mediaPathClientEvidenceByStreamID.removeValue(forKey: streamID)
        let removedSession = activeSessionByStreamID.removeValue(forKey: streamID)
        activeStreams.removeAll { $0.id == streamID }

        if let removedSession,
           activeStreamIDByWindowID[removedSession.window.id] == streamID {
            activeStreamIDByWindowID.removeValue(forKey: removedSession.window.id)
            lastWindowPlacementRepairAtByWindowID.removeValue(forKey: removedSession.window.id)
        }

        if let mappedWindowID = activeWindowIDByStreamID.removeValue(forKey: streamID),
           activeStreamIDByWindowID[mappedWindowID] == streamID {
            activeStreamIDByWindowID.removeValue(forKey: mappedWindowID)
            lastWindowPlacementRepairAtByWindowID.removeValue(forKey: mappedWindowID)
        }

        syncSharedClipboardState()
        if removedSession != nil {
            notifyActiveStreamActivityChanged()
        }
    }
}
#endif
