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
                        MirageLogger.error(
                            .host,
                            "Client \(client.name) fatal connection error - disconnecting: \(error)"
                        )
                    case let .persistentError(error):
                        MirageLogger.error(
                            .host,
                            "Client \(client.name) persistent receive errors - disconnecting: \(error)"
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
