//
//  MirageHostService+StreamStartupHelpers.swift
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
    /// Returns the current client context for a stream startup request.
    func startupClientContext(
        for client: MirageConnectedClient,
        expectedSessionID: UUID?
    ) throws -> ClientContext {
        if let expectedSessionID {
            guard let currentClientContext = findClientContext(sessionID: expectedSessionID),
                  currentClientContext.client.id == client.id else {
                throw MirageCore.MirageError.protocolError("Client session is disconnected or superseded")
            }
            return currentClientContext
        }

        guard let currentClientContext = findClientContext(clientID: client.id) else {
            throw MirageCore.MirageError.protocolError("Client context missing for stream start")
        }
        return currentClientContext
    }
}

#endif
