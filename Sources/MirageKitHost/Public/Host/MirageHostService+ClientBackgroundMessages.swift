//
//  MirageHostService+ClientBackgroundMessages.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Handles a client-background lease and pauses active stream contexts.
    func handleStreamPauseAll(_ message: MirageWire.ControlMessage, from clientContext: ClientContext) async {
        if !message.payload.isEmpty {
            do {
                let lease = try message.decode(MirageWire.ClientBackgroundLeaseMessage.self)
                scheduleBackgroundLease(lease, for: clientContext)
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to decode client background lease: ")
            }
        }

        let contextCount = streamsByID.count
        guard contextCount > 0 else { return }
        MirageLogger.host("Pausing all streams (\(contextCount)) for client background")
        resetDesktopResizeTransactionState()
        for (_, context) in streamsByID {
            await context.pauseForClientBackground()
        }
    }

    /// Resumes active stream contexts after the client returns to the foreground.
    func handleStreamResumeAll(from clientContext: ClientContext) async {
        cancelBackgroundLease(clientID: clientContext.client.id)

        let contextCount = streamsByID.count
        guard contextCount > 0 else { return }
        MirageLogger.host("Resuming all streams (\(contextCount)) after client foreground")
        for (_, context) in streamsByID {
            await context.resumeAfterClientForeground()
        }
    }
}
#endif
