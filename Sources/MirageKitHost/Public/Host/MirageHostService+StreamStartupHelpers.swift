//
//  MirageHostService+StreamStartupHelpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

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
                throw MirageError.protocolError("Client session is disconnected or superseded")
            }
            return currentClientContext
        }

        guard let currentClientContext = findClientContext(clientID: client.id) else {
            throw MirageError.protocolError("Client context missing for stream start")
        }
        return currentClientContext
    }
}

#endif
