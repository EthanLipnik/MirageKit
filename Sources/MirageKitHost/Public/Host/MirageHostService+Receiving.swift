//
//  MirageHostService+Receiving.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Control message receiving loop.
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
    /// Continuously receive and handle control messages from a client.
    func startReceivingFromClient(clientContext: ClientContext) {
        let source = MirageStreamReceiveSource(stream: clientContext.controlChannel.incomingBytes)

        let clientID = clientContext.client.id
        let activityTracker = clientLastActivityByID
        recordClientActivity(clientID: clientID)
        let inputScheduler = HostInputMessageScheduler(inputQueue: inputQueue) { [weak self] message in
            guard let self else { return }
            handleInputEventFast(message, from: clientContext.client, sessionID: clientContext.sessionID)
        }
        let priorityInputRoute = HostPriorityInputRoute(
            sessionID: clientContext.sessionID,
            clientName: clientContext.client.name,
            controlChannel: clientContext.controlChannel,
            inputScheduler: inputScheduler
        )
        storePriorityInputRoute(priorityInputRoute, sessionID: clientContext.sessionID)
        priorityInputRoute.startIfAvailable(clientContext: clientContext)

        let receiveLoop = HostReceiveLoop(
            clientName: clientContext.client.name,
            maxControlBacklog: 256,
            errorTimeoutSeconds: clientErrorTimeoutSeconds,
            receiveChunk: { completion in
                source.receiveNext { data, context, isComplete, error in
                    if data != nil {
                        activityTracker.withLock { $0[clientID] = CFAbsoluteTimeGetCurrent() }
                    }
                    completion(data, context, isComplete, error)
                }
            },
            onInputMessage: { message in
                priorityInputRoute.handleControlInputMessage(message)
            },
            onPingMessage: {
                clientContext.sendBestEffort(.pong)
            },
            onLifecycleSignal: { [weak self] signal in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch signal {
                    case .disconnect:
                        markStreamSetupSessionClosing(clientSessionID: clientContext.sessionID)
                        await disconnectClient(
                            clientContext.client,
                            sessionID: clientContext.sessionID,
                            notifyClient: false
                        )
                    case let .cancelStreamSetup(message):
                        let request: MirageWire.CancelStreamSetupMessage
                        do {
                            request = try message.decode(MirageWire.CancelStreamSetupMessage.self)
                        } catch {
                            MirageLogger.error(.host, error: error, message: "Failed to decode cancel stream setup signal: ")
                            return
                        }

                        if let startupRequestID = request.startupRequestID {
                            cancelStreamSetup(
                                clientSessionID: clientContext.sessionID,
                                startupRequestID: startupRequestID
                            )
                        } else {
                            cancelAllStreamSetup(clientSessionID: clientContext.sessionID)
                        }
                    case let .streamReady(message):
                        guard let liveClientContext = findClientContext(sessionID: clientContext.sessionID) else {
                            return
                        }
                        await handleClientMessage(message, from: liveClientContext)
                    case .terminal:
                        markStreamSetupSessionClosing(clientSessionID: clientContext.sessionID)
                        await disconnectClient(
                            clientContext.client,
                            sessionID: clientContext.sessionID,
                            notifyClient: false
                        )
                    }
                }
            },
            dispatchControlMessage: { [weak self] message, completion in
                guard let self else {
                    completion()
                    return
                }
                dispatchControlWork(clientID: clientContext.client.id, completion: completion) { [weak self] in
                    guard let self else { return }
                    guard let liveClientContext = findClientContext(sessionID: clientContext.sessionID) else {
                        return
                    }
                    await handleClientMessage(message, from: liveClientContext)
                }
            },
            onTerminal: { [weak self] reason in
                guard let self else { return }
                dispatchControlWork(clientID: clientContext.client.id) { [weak self] in
                    guard let self else { return }
                    removeReceiveLoop(sessionID: clientContext.sessionID)
                    stopPriorityInputRoute(sessionID: clientContext.sessionID)

                    switch reason {
                    case .complete:
                        MirageLogger.host("Client disconnected")
                    case let .fatalError(error):
                        if MirageConnectionErrorClassifier.isLikelyUserDependent(error: error) {
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
                        if MirageConnectionErrorClassifier.isLikelyUserDependent(error: error) {
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

                    await disconnectClient(
                        clientContext.client,
                        sessionID: clientContext.sessionID,
                        notifyClient: false
                    )
                }
            },
            isFatalError: { [weak self] error in
                guard let self else { return true }
                return isFatalConnectionError(error)
            }
        )

        storeReceiveLoop(receiveLoop, sessionID: clientContext.sessionID)
        receiveLoop.start()
    }
}
#endif
