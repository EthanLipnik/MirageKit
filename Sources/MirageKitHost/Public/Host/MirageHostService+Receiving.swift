//
//  MirageHostService+Receiving.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Control message receiving loop.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Continuously receive and handle control messages from a client.
    func startReceivingFromClient(
        connection: NWConnection,
        client: MirageConnectedClient,
        initialBuffer: Data = Data()
    ) {
        let connectionID = ObjectIdentifier(connection)

        let receiveLoop = HostReceiveLoop(
            connection: connection,
            clientName: client.name,
            maxControlBacklog: 256,
            errorTimeoutSeconds: clientErrorTimeoutSeconds,
            onInputMessage: { [weak self] message in
                guard let self else { return }
                self.inputQueue.async { [weak self] in
                    guard let self else { return }
                    self.handleInputEventFast(message, from: client)
                }
            },
            dispatchControlMessage: { [weak self] message, completion in
                guard let self else {
                    completion()
                    return
                }
                self.dispatchControlWork(clientID: client.id, completion: completion) { [weak self] in
                    guard let self else { return }
                    guard self.clientsByID[client.id] != nil else { return }
                    await self.handleClientMessage(message, from: client, connection: connection)
                }
            },
            onTerminal: { [weak self] reason in
                guard let self else { return }
                self.dispatchControlWork(clientID: client.id) { [weak self] in
                    guard let self else { return }
                    self.removeReceiveLoop(connectionID: connectionID)

                    switch reason {
                    case .complete:
                        MirageLogger.host("Client disconnected")
                    case let .fatalError(error):
                        if LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
                            MirageLogger.host(
                                "Client \(client.name) disconnected after fatal transport error: \(error)"
                            )
                        } else {
                            MirageLogger.error(
                                .host,
                                "Client \(client.name) fatal connection error - disconnecting: \(error)"
                            )
                        }
                    case let .persistentError(error):
                        if LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
                            MirageLogger.host(
                                "Client \(client.name) disconnected after persistent transport errors: \(error)"
                            )
                        } else {
                            MirageLogger.error(
                                .host,
                                "Client \(client.name) persistent receive errors - disconnecting: \(error)"
                            )
                        }
                    case let .protocolViolation(reason):
                        MirageLogger.error(
                            .host,
                            "Client \(client.name) protocol violation - disconnecting: \(reason)"
                        )
                    case let .receiveBufferOverflow(limit):
                        MirageLogger.error(
                            .host,
                            "Client \(client.name) control receive buffer exceeded \(limit) bytes - disconnecting"
                        )
                    }

                    if self.clientsByID[client.id] != nil {
                        await self.disconnectClient(client)
                    }
                }
            },
            isFatalError: { [weak self] error in
                guard let self else { return true }
                return self.isFatalConnectionError(error)
            }
        )

        self.storeReceiveLoop(receiveLoop, connectionID: connectionID)
        receiveLoop.start(initialBuffer: initialBuffer)
    }
}
#endif
