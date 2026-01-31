//
//  MirageClientService+Connection.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Client connection lifecycle and hello handshake.
//

import Foundation
import Network

#if canImport(UIKit)
import UIKit.UIDevice
#endif

#if canImport(AppKit)
import AppKit
#endif

@MainActor
extension MirageClientService {
    /// Determine current device type.
    private var currentDeviceType: DeviceType {
        #if os(macOS)
        return .mac
        #elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .iPad
        } else {
            return .iPhone
        }
        #elseif os(visionOS)
        return .vision
        #else
        return .unknown
        #endif
    }

    /// Send hello message with device info to host.
    private func sendHelloMessage(connection: NWConnection) async {
        let hello = HelloMessage(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: currentDeviceType,
            protocolVersion: Int(MirageKit.protocolVersion),
            capabilities: MirageHostCapabilities(
                maxStreams: 4,
                supportsHEVC: true,
                supportsP3ColorSpace: true,
                maxFrameRate: 120,
                protocolVersion: Int(MirageKit.protocolVersion)
            ),
            iCloudUserID: iCloudUserID
        )

        do {
            let message = try ControlMessage(type: .hello, content: hello)
            let data = message.serialize()
            MirageLogger.client("Sending hello: \(deviceName) (\(currentDeviceType.displayName))")

            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    MirageLogger.error(.client, "Failed to send hello: \(error)")
                } else {
                    MirageLogger.client("Hello sent successfully")
                }
            })
        } catch {
            MirageLogger.error(.client, "Failed to create hello message: \(error)")
        }
    }

    /// Connect to a discovered host.
    public func connect(to host: MirageHost) async throws {
        guard connectionState.canConnect else {
            throw MirageError.protocolError("Already connected or connecting")
        }

        MirageLogger.client("Connecting to \(host.name)...")
        connectionState = .connecting
        connectedHost = host

        do {
            // Create a direct TCP connection to the Bonjour endpoint.
            let parameters = NWParameters.tcp
            parameters.serviceClass = .interactiveVideo
            parameters.includePeerToPeer = networkConfig.enablePeerToPeer

            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveInterval = 5
            }

            let connection = NWConnection(to: host.endpoint, using: parameters)

            // Wait for connection to be ready.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let continuationBox = ContinuationBox<Void>(continuation)

                connection.stateUpdateHandler = { [continuationBox] state in
                    MirageLogger.client("Connection state: \(state)")
                    switch state {
                    case .ready:
                        continuationBox.resume()
                    case .failed(let error):
                        continuationBox.resume(throwing: error)
                    case .cancelled:
                        continuationBox.resume(throwing: MirageError.protocolError("Connection cancelled"))
                    case .waiting(let error):
                        MirageLogger.client("Connection waiting: \(error)")
                    default:
                        break
                    }
                }

                connection.start(queue: .global(qos: .userInitiated))
            }

            MirageLogger.client("Connected to \(host.name)")
            connectionState = .connected(host: host.name)

            // Store connection for receiving messages.
            self.connection = connection

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    Task { @MainActor in
                        await self.handleDisconnect(
                            reason: error.localizedDescription,
                            state: .error(error.localizedDescription),
                            notifyDelegate: true
                        )
                    }
                case .cancelled:
                    Task { @MainActor in
                        await self.handleDisconnect(
                            reason: "Connection cancelled",
                            state: .disconnected,
                            notifyDelegate: true
                        )
                    }
                default:
                    break
                }
            }

            // Send hello message with device info.
            await sendHelloMessage(connection: connection)

            // Start receiving messages from the server.
            startReceiving()

        } catch {
            MirageLogger.error(.client, "Connection failed: \(error)")
            connectionState = .disconnected
            connectedHost = nil
            transport = nil
            throw error
        }
    }

    /// Disconnect from the current host.
    public func disconnect() async {
        // Send disconnect message to host before closing connection.
        if let connection, case .connected = connectionState {
            let disconnectMsg = DisconnectMessage(reason: .userRequested, message: nil)
            if let message = try? ControlMessage(type: .disconnect, content: disconnectMsg) {
                let data = message.serialize()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    connection.send(content: data, completion: .contentProcessed { _ in
                        continuation.resume()
                    })
                }
            }
        }

        await handleDisconnect(
            reason: DisconnectMessage.DisconnectReason.userRequested.rawValue,
            state: .disconnected,
            notifyDelegate: false
        )
    }

    func handleDisconnect(reason: String, state: ConnectionState, notifyDelegate: Bool) async {
        if case .disconnected = connectionState {
            return
        }

        if case .error = connectionState, case .error = state {
            return
        }

        let sessions = activeStreams
        let storedSessions = sessionStore.activeSessions

        connection?.cancel()
        connection = nil
        receiveBuffer = Data()
        await transport?.disconnect()
        transport = nil
        connectedHost = nil
        availableWindows = []
        hasReceivedWindowList = false
        availableApps = []
        hasReceivedAppList = false
        streamingAppBundleID = nil

        for session in sessions {
            await stopViewing(session)
        }

        if let loginDisplayStreamID {
            MirageFrameCache.shared.clear(for: loginDisplayStreamID)
        }
        metricsStore.clearAll()
        cursorStore.clearAll()
        sessionStore.clearLoginDisplayState()

        // Clean up video resources.
        stopVideoConnection()
        stopAudioPlayback()

        let controllers = controllersByStream.values
        for controller in controllers {
            await controller.stop()
        }
        controllersByStream.removeAll()
        registeredStreamIDs.removeAll()
        desktopStreamRequestStartTime = 0
        streamStartupBaseTimes.removeAll()
        streamStartupFirstRegistrationSent.removeAll()
        streamStartupFirstPacketReceived.removeAll()
        startupPacketPendingLock.withLock {
            _startupPacketPending.removeAll()
        }
        activeStreams.removeAll()
        for session in storedSessions {
            sessionStore.removeSession(session.id)
        }
        await updateReassemblerSnapshot()

        // Clear active stream IDs (thread-safe).
        clearAllActiveStreamIDs()

        // Reset session state.
        hostSessionState = nil
        currentSessionToken = nil
        loginDisplayStreamID = nil
        loginDisplayResolution = nil
        desktopStreamID = nil
        desktopStreamResolution = nil
        connectionState = state

        if notifyDelegate {
            delegate?.clientService(self, didDisconnectFromHost: reason)
        }
    }
}
