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
    func startReceivingFromClient(clientContext: ClientContext, initialBuffer: Data = Data()) {
        let source = MirageStreamReceiveSource(stream: clientContext.controlChannel.incomingBytes)

        let receiveLoop = HostReceiveLoop(
            clientName: clientContext.client.name,
            maxControlBacklog: 256,
            errorTimeoutSeconds: clientErrorTimeoutSeconds,
            receiveChunk: source.receiveNext,
            onInputMessage: { [weak self] message in
                guard let self else { return }
                self.inputQueue.async { [weak self] in
                    guard let self else { return }
                    self.handleInputEventFast(message, from: clientContext.client)
                }
            },
            onPingMessage: { _ in
                clientContext.sendBestEffort(ControlMessage(type: .pong))
            },
            dispatchControlMessage: { [weak self] message, completion in
                guard let self else {
                    completion()
                    return
                }
                self.dispatchControlWork(clientID: clientContext.client.id, completion: completion) { [weak self] in
                    guard let self else { return }
                    guard let liveClientContext = self.clientsByID[clientContext.client.id] else { return }
                    await self.handleClientMessage(message, from: liveClientContext)
                }
            },
            onTerminal: { [weak self] reason in
                guard let self else { return }
                self.dispatchControlWork(clientID: clientContext.client.id) { [weak self] in
                    guard let self else { return }
                    self.removeReceiveLoop(sessionID: clientContext.sessionID)

                    switch reason {
                    case .complete:
                        MirageLogger.host("Client disconnected")
                    case let .fatalError(error):
                        if LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
                            MirageLogger.host(
                                "Client \(clientContext.client.name) disconnected after fatal transport error: \(error)"
                            )
                        } else {
                            MirageLogger.error(
                                .host,
                                "Client \(clientContext.client.name) fatal connection error - disconnecting: \(error)"
                            )
                        }
                    case let .persistentError(error):
                        if LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
                            MirageLogger.host(
                                "Client \(clientContext.client.name) disconnected after persistent transport errors: \(error)"
                            )
                        } else {
                            MirageLogger.error(
                                .host,
                                "Client \(clientContext.client.name) persistent receive errors - disconnecting: \(error)"
                            )
                        }
                    case let .protocolViolation(reason):
                        MirageLogger.host(
                            "Client \(clientContext.client.name) protocol violation - disconnecting: \(reason)"
                        )
                    case let .receiveBufferOverflow(limit):
                        MirageLogger.error(
                            .host,
                            "Client \(clientContext.client.name) control receive buffer exceeded \(limit) bytes - disconnecting"
                        )
                    }

                    await self.disconnectClient(clientContext.client)
                }
            },
            isFatalError: { [weak self] error in
                guard let self else { return true }
                return self.isFatalConnectionError(error)
            }
        )

        self.storeReceiveLoop(receiveLoop, sessionID: clientContext.sessionID)
        receiveLoop.start(initialBuffer: initialBuffer)
    }
}
#endif
