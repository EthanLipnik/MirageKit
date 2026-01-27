//
//  MirageHostService+Connections.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  TCP connection lifecycle and hello handshake.
//

import Foundation
import Network

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Check if an error indicates a fatal, unrecoverable connection state.
    func isFatalConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let fatalPosixCodes = [54, 57, 32, 104]
        if nsError.domain == NSPOSIXErrorDomain && fatalPosixCodes.contains(nsError.code) {
            return true
        }
        if nsError.domain == "NWError" && (nsError.code == -65554 || nsError.code == -65555) {
            return true
        }
        return false
    }

    func handleNewConnection(_ connection: NWConnection) async {
        MirageLogger.host("New client connection")

        connection.start(queue: .global(qos: .userInitiated))

        let isReady = await withCheckedContinuation { continuation in
            let box = SafeContinuationBox<Bool>(continuation)
            connection.stateUpdateHandler = { [box] state in
                switch state {
                case .ready:
                    box.resume(returning: true)
                case .failed, .cancelled:
                    box.resume(returning: false)
                default:
                    break
                }
            }
        }

        guard isReady else {
            MirageLogger.host("Client connection failed")
            return
        }

        let endpointDescription: String
        switch connection.endpoint {
        case .hostPort(let host, let port):
            endpointDescription = "\(host):\(port)"
        case .service(let name, _, _, _):
            endpointDescription = name
        default:
            endpointDescription = connection.endpoint.debugDescription
        }

        MirageLogger.host("Waiting for hello message from \(endpointDescription)...")

        let deviceInfo = await receiveHelloMessage(from: connection, endpoint: endpointDescription)
        let connectionID = ObjectIdentifier(connection)

        guard reserveSingleClientSlot(for: connectionID) else {
            if let activeClient = clientsByConnection.values.first?.client {
                MirageLogger.host(
                    "Rejecting \(deviceInfo.name); host already has active client \(activeClient.name)"
                )
            } else {
                MirageLogger.host("Rejecting \(deviceInfo.name); host already has a pending client")
            }
            sendHelloResponse(
                accepted: false,
                to: connection,
                dataPort: currentDataPort(),
                cancelAfterSend: true
            )
            return
        }

        defer {
            if clientsByConnection[connectionID] == nil {
                releaseSingleClientSlot(for: connectionID)
            }
        }

        MirageLogger.host("Requesting approval for \(deviceInfo.name) (\(deviceInfo.deviceType.displayName))...")

        let shouldAccept: Bool = await withCheckedContinuation { continuation in
            let box = SafeContinuationBox<Bool>(continuation)
            if let delegate {
                delegate.hostService(self, shouldAcceptConnectionFrom: deviceInfo) { accepted in
                    box.resume(returning: accepted)
                }
            } else {
                box.resume(returning: true)
            }
        }

        guard shouldAccept else {
            MirageLogger.host("Connection rejected by user")
            connection.cancel()
            return
        }

        MirageLogger.host("Connection approved, sending hello response...")
        sendHelloResponse(
            accepted: true,
            to: connection,
            dataPort: currentDataPort(),
            cancelAfterSend: false
        )

        let client = MirageConnectedClient(
            id: deviceInfo.id,
            name: deviceInfo.name,
            deviceType: deviceInfo.deviceType,
            connectedAt: Date()
        )

        let clientContext = ClientContext(
            client: client,
            tcpConnection: connection,
            udpConnection: nil
        )
        clientsByConnection[ObjectIdentifier(connection)] = clientContext

        connectedClients.append(client)
        delegate?.hostService(self, didConnectClient: client)

        startSessionRefreshLoopIfNeeded()
        await refreshSessionStateIfNeeded()
        await sendSessionState(to: clientContext)

        if sessionState == .active {
            await sendWindowList(to: clientContext)
        } else {
            await startLoginDisplayStreamIfNeeded()
            MirageLogger.host("Session is \(sessionState), client will show unlock form")
        }

        startReceivingFromClient(connection: connection, client: client)
    }

    /// Receive hello message from a connecting client.
    func receiveHelloMessage(from connection: NWConnection, endpoint: String) async -> MirageDeviceInfo {
        let result: (Data?, NWConnection.ContentContext?, Bool, NWError?) = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, context, isComplete, error in
                continuation.resume(returning: (data, context, isComplete, error))
            }
        }

        let (data, _, _, error) = result

        if let error {
            MirageLogger.error(.host, "Error receiving hello: \(error)")
            return MirageDeviceInfo(name: "Unknown Device", deviceType: .unknown, endpoint: endpoint)
        }

        guard let data, !data.isEmpty else {
            MirageLogger.host("No data received for hello")
            return MirageDeviceInfo(name: "Unknown Device", deviceType: .unknown, endpoint: endpoint)
        }

        guard let (message, _) = ControlMessage.deserialize(from: data) else {
            MirageLogger.host("Failed to deserialize hello message")
            return MirageDeviceInfo(name: "Unknown Device", deviceType: .unknown, endpoint: endpoint)
        }

        guard message.type == .hello else {
            MirageLogger.host("Expected hello message, got \(message.type)")
            return MirageDeviceInfo(name: "Unknown Device", deviceType: .unknown, endpoint: endpoint)
        }

        do {
            let hello = try message.decode(HelloMessage.self)
            MirageLogger.host("Received hello from \(hello.deviceName) (\(hello.deviceType.displayName))")
            return MirageDeviceInfo(
                id: hello.deviceID,
                name: hello.deviceName,
                deviceType: hello.deviceType,
                endpoint: endpoint
            )
        } catch {
            MirageLogger.error(.host, "Failed to decode hello: \(error)")
            return MirageDeviceInfo(name: "Unknown Device", deviceType: .unknown, endpoint: endpoint)
        }
    }

    private func currentDataPort() -> UInt16 {
        if case .advertising(_, let port) = state {
            return port
        }
        return 0
    }

    func reserveSingleClientSlot(for connectionID: ObjectIdentifier) -> Bool {
        if let reservedID = singleClientConnectionID, reservedID != connectionID {
            return false
        }

        if let existingConnectionID = clientsByConnection.keys.first, existingConnectionID != connectionID {
            singleClientConnectionID = existingConnectionID
            return false
        }

        singleClientConnectionID = connectionID
        return true
    }

    func releaseSingleClientSlot(for connectionID: ObjectIdentifier) {
        if singleClientConnectionID == connectionID {
            singleClientConnectionID = nil
        }
    }

    private func sendHelloResponse(
        accepted: Bool,
        to connection: NWConnection,
        dataPort: UInt16,
        cancelAfterSend: Bool
    ) {
        do {
            let hostName = Host.current().localizedName ?? "Mac"
            let response = HelloResponseMessage(
                accepted: accepted,
                hostID: hostID,
                hostName: hostName,
                requiresAuth: false,
                dataPort: dataPort
            )
            let message = try ControlMessage(type: .helloResponse, content: response)
            let data = message.serialize()

            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    MirageLogger.error(.host, "Failed to send hello response: \(error)")
                } else if accepted {
                    MirageLogger.host("Sent hello response with dataPort \(dataPort)")
                } else {
                    MirageLogger.host("Sent rejection hello response")
                }

                if cancelAfterSend {
                    connection.cancel()
                }
            })
        } catch {
            MirageLogger.error(.host, "Failed to create hello response: \(error)")
            if cancelAfterSend {
                connection.cancel()
            }
        }
    }
}
#endif
