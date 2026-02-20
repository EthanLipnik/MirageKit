//
//  MirageHostService+UDP.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  UDP listener and video registration handling.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func startDataListener() async throws -> UInt16 {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = networkConfig.enablePeerToPeer

        let port: NWEndpoint.Port = networkConfig.dataPort == 0 ? .any : NWEndpoint
            .Port(rawValue: networkConfig.dataPort) ?? .any

        let listener = try NWListener(using: params, on: port)
        udpListener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInteractive))
            Task { @MainActor [weak self] in
                await self?.handleIncomingVideoConnection(connection)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ContinuationBox<UInt16>(continuation)

            listener.stateUpdateHandler = { [continuationBox] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { continuationBox.resume(returning: port) }
                case let .failed(error):
                    continuationBox.resume(throwing: error)
                case .cancelled:
                    continuationBox.resume(throwing: MirageError.protocolError("Listener cancelled"))
                default:
                    break
                }
            }

            listener.start(queue: .global(qos: .userInteractive))
        }
    }

    /// Handle an incoming UDP connection from a client (for video data).
    func handleIncomingVideoConnection(_ connection: NWConnection) async {
        while true {
            let result: (
                Data?,
                NWConnection.ContentContext?,
                Bool,
                NWError?
            ) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 20, maximumLength: 64) { data, context, isComplete, error in
                    continuation.resume(returning: (data, context, isComplete, error))
                }
            }

            if let error = result.3 {
                MirageLogger.host("UDP connection error: \(error)")
                break
            }

            guard let data = result.0, data.count >= 20 else {
                if result.2 {
                    MirageLogger.host("UDP connection closed (no more data)")
                    break
                }
                MirageLogger.host("Invalid video registration packet")
                continue
            }

            let magic = data.prefix(4)
            if magic.elementsEqual([0x4D, 0x49, 0x52, 0x51]) {
                let minimumLength = 20 + MirageMediaSecurity.registrationTokenLength
                guard data.count >= minimumLength else {
                    MirageLogger.host("Invalid quality-test registration packet length \(data.count)")
                    continue
                }
                let uuidBytes: uuid_t = data.withUnsafeBytes { ptr in
                    ptr.loadUnaligned(fromByteOffset: 4, as: uuid_t.self)
                }
                let deviceID = UUID(uuid: uuidBytes)
                guard validateRegistrationToken(
                    data: data,
                    tokenOffset: 20,
                    clientID: deviceID,
                    channel: "quality-test",
                    streamID: nil
                ) else {
                    continue
                }
                qualityTestConnectionsByClientID[deviceID] = connection
                transportRegistry.registerQualityConnection(connection, clientID: deviceID)
                let pathText = connection.currentPath.map(describeNetworkPath) ?? "unknown"
                MirageLogger.host("Registered quality test UDP connection for device \(deviceID.uuidString) (\(pathText))")
                continue
            }

            if magic.elementsEqual([0x4D, 0x49, 0x52, 0x41]) {
                let minimumLength = 22 + MirageMediaSecurity.registrationTokenLength
                guard data.count >= minimumLength else {
                    MirageLogger.host("Invalid audio registration packet")
                    continue
                }
                let streamID = data.dropFirst(4).prefix(2).withUnsafeBytes { ptr in
                    ptr.loadUnaligned(fromByteOffset: 0, as: StreamID.self).littleEndian
                }
                let uuidBytes: uuid_t = data.withUnsafeBytes { ptr in
                    ptr.loadUnaligned(fromByteOffset: 6, as: uuid_t.self)
                }
                let deviceID = UUID(uuid: uuidBytes)
                guard validateRegistrationToken(
                    data: data,
                    tokenOffset: 22,
                    clientID: deviceID,
                    channel: "audio",
                    streamID: streamID
                ) else {
                    continue
                }
                audioConnectionsByClientID[deviceID] = connection
                transportRegistry.registerAudioConnection(connection, clientID: deviceID)
                let pathText = connection.currentPath.map(describeNetworkPath) ?? "unknown"
                MirageLogger.host(
                    "Registered audio UDP connection for device \(deviceID.uuidString), stream \(streamID) (\(pathText))"
                )
                await handleAudioConnectionRegistered(clientID: deviceID, streamID: streamID)
                continue
            }

            guard magic.elementsEqual([0x4D, 0x49, 0x52, 0x47]) else {
                MirageLogger.host("Invalid video registration magic")
                continue
            }
            let minimumLength = 22 + MirageMediaSecurity.registrationTokenLength
            guard data.count >= minimumLength else {
                MirageLogger.host("Invalid video registration packet length \(data.count)")
                continue
            }

            let streamID = data.dropFirst(4).prefix(2).withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: 0, as: StreamID.self).littleEndian
            }
            let uuidBytes: uuid_t = data.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: 6, as: uuid_t.self)
            }
            let deviceID = UUID(uuid: uuidBytes)
            guard validateRegistrationToken(
                data: data,
                tokenOffset: 22,
                clientID: deviceID,
                channel: "video",
                streamID: streamID
            ) else {
                continue
            }

            let pathText = connection.currentPath.map(describeNetworkPath) ?? "unknown"
            MirageLogger.host("Received video registration for stream \(streamID) client \(deviceID) (\(pathText))")

            guard streamsByID[streamID] != nil else {
                MirageLogger.host("Stream \(streamID) not found, may be pending")
                continue
            }

            if let baseTime = streamStartupBaseTimes[streamID],
               !streamStartupRegistrationLogged.contains(streamID) {
                streamStartupRegistrationLogged.insert(streamID)
                let deltaMs = Int((CFAbsoluteTimeGetCurrent() - baseTime) * 1000)
                MirageLogger.host("Desktop start: UDP registration received for stream \(streamID) (+\(deltaMs)ms)")
            }

            udpConnectionsByStream[streamID] = connection
            transportRegistry.registerVideoConnection(connection, streamID: streamID)

            MirageLogger.host("UDP connection registered for stream \(streamID)")

            if let context = streamsByID[streamID] {
                MirageLogger.host("Enabling encoding after UDP registration for stream \(streamID)")
                await context.allowEncodingAfterRegistration()
            } else {
                MirageLogger.host("WARNING: No stream context found for stream \(streamID)")
            }
        }
    }

    private func validateRegistrationToken(
        data: Data,
        tokenOffset: Int,
        clientID: UUID,
        channel: String,
        streamID: StreamID?
    ) -> Bool {
        let tokenLength = MirageMediaSecurity.registrationTokenLength
        let streamText = streamID.map { "\($0)" } ?? "-"
        guard data.count >= tokenOffset + tokenLength else {
            MirageLogger.host(
                "Rejected \(channel) registration missing token (client \(clientID), stream \(streamText))"
            )
            return false
        }
        let token = Data(data[tokenOffset ..< tokenOffset + tokenLength])
        guard let context = mediaSecurityByClientID[clientID] else {
            MirageLogger.host(
                "Rejected \(channel) registration without media context (client \(clientID), stream \(streamText))"
            )
            return false
        }
        if !MirageMediaSecurity.constantTimeEqual(token, context.udpRegistrationToken) {
            MirageLogger.error(
                .host,
                "Rejected \(channel) registration with invalid token (client \(clientID), stream \(streamText))"
            )
            return false
        }
        return true
    }
}

private func describeNetworkPath(_ path: NWPath) -> String {
    var interfaces: [String] = []
    if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
    if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wired") }
    if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
    if path.usesInterfaceType(.loopback) { interfaces.append("loopback") }
    if path.usesInterfaceType(.other) { interfaces.append("other") }
    let interfaceText = interfaces.isEmpty ? "unknown" : interfaces.joined(separator: ",")
    let available = path.availableInterfaces
        .map { "\($0.name)(\(String(describing: $0.type)))" }
        .joined(separator: ",")
    let availableText = available.isEmpty ? "none" : available
    return "status=\(path.status), interfaces=\(interfaceText), available=\(availableText), expensive=\(path.isExpensive), constrained=\(path.isConstrained), ipv4=\(path.supportsIPv4), ipv6=\(path.supportsIPv6)"
}
#endif
