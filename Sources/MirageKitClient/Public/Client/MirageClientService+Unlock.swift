//
//  MirageClientService+Unlock.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host unlock request handling.
//

import Foundation
import MirageKit

@MainActor
public extension MirageClientService {
    /// Send an unlock request to the host.
    /// - Parameters:
    ///   - username: Username (required if host is at login screen).
    ///   - password: Password for the account.
    /// - Throws: Error if not connected or no session token.
    func sendUnlockRequest(username: String?, password: String) async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected to host") }

        guard let token = currentSessionToken else { throw MirageError.protocolError("No session token available") }

        let request = UnlockRequestMessage(
            sessionToken: token,
            username: username,
            password: password
        )

        MirageInstrumentation.record(.clientUnlockRequested)
        try await sendControlMessage(.unlockRequest, content: request)
        MirageLogger.client("Sent unlock request")
    }
}
