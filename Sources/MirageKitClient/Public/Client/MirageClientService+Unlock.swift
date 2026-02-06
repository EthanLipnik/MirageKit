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
        guard let connection else { throw MirageError.protocolError("Not connected to host") }

        guard let token = currentSessionToken else { throw MirageError.protocolError("No session token available") }

        let request = UnlockRequestMessage(
            sessionToken: token,
            username: username,
            password: password
        )

        let message = try ControlMessage(type: .unlockRequest, content: request)
        let data = message.serialize()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    MirageLogger.client("Sent unlock request")
                    continuation.resume()
                }
            })
        }
    }
}
