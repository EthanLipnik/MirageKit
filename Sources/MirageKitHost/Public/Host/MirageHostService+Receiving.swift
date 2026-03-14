//
//  MirageHostService+Receiving.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Control message receiving loop.
//

import Foundation
import Loom
import Network
import MirageKit

#if os(macOS)
private final class MirageStreamReceiveSource: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferedChunks: [Data] = []
    private var waitingCompletion: (@Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?
    private var finished = false

    init(stream: AsyncStream<Data>) {
        Task {
            for await chunk in stream {
                self.push(chunk)
            }
            self.finish()
        }
    }

    func receiveNext(
        _ completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void
    ) {
        lock.lock()
        if !bufferedChunks.isEmpty {
            let chunk = bufferedChunks.removeFirst()
            lock.unlock()
            completion(chunk, nil, false, nil)
            return
        }
        if finished {
            lock.unlock()
            completion(nil, nil, true, nil)
            return
        }
        waitingCompletion = completion
        lock.unlock()
    }

    private func push(_ chunk: Data) {
        lock.lock()
        if let waitingCompletion {
            self.waitingCompletion = nil
            lock.unlock()
            waitingCompletion(chunk, nil, false, nil)
            return
        }
        bufferedChunks.append(chunk)
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        finished = true
        let waitingCompletion = waitingCompletion
        self.waitingCompletion = nil
        lock.unlock()
        waitingCompletion?(nil, nil, true, nil)
    }
}

@MainActor
extension MirageHostService {
    /// Continuously receive and handle control messages from a client.
    func startReceivingFromClient(
        controlChannel: MirageControlChannel,
        client: MirageConnectedClient,
        initialBuffer: Data = Data()
    ) {
        let connection = controlChannel.rawConnection
        let connectionID = ObjectIdentifier(connection)

        let source = MirageStreamReceiveSource(stream: controlChannel.incomingBytes)

        let receiveLoop = HostReceiveLoop(
            clientName: client.name,
            maxControlBacklog: 256,
            errorTimeoutSeconds: clientErrorTimeoutSeconds,
            receiveChunk: source.receiveNext,
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
