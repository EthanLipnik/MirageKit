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
                let uuidBytes: uuid_t = data.withUnsafeBytes { ptr in
                    ptr.loadUnaligned(fromByteOffset: 4, as: uuid_t.self)
                }
                let deviceID = UUID(uuid: uuidBytes)
                qualityTestConnectionsByClientID[deviceID] = connection
                let pathText = connection.currentPath.map(describeNetworkPath) ?? "unknown"
                MirageLogger.host("Registered quality test UDP connection for device \(deviceID.uuidString) (\(pathText))")
                continue
            }

            guard magic.elementsEqual([0x4D, 0x49, 0x52, 0x47]) else {
                MirageLogger.host("Invalid video registration magic")
                continue
            }

            let streamID = data.dropFirst(4).prefix(2).withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: 0, as: StreamID.self).littleEndian
            }

            let pathText = connection.currentPath.map(describeNetworkPath) ?? "unknown"
            MirageLogger.host("Received video registration for stream \(streamID) (\(pathText))")

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

            MirageLogger.host("UDP connection registered for stream \(streamID)")

            if let context = streamsByID[streamID] {
                MirageLogger.host("Enabling encoding after UDP registration for stream \(streamID)")
                await context.allowEncodingAfterRegistration()
            } else {
                MirageLogger.host("WARNING: No stream context found for stream \(streamID)")
            }
        }
    }

    /// Send video packet for a specific stream.
    func sendVideoPacketForStream(_ streamID: StreamID, data: Data, onComplete: (@Sendable () -> Void)? = nil) {
        guard let connection = udpConnectionsByStream[streamID] else {
            onComplete?()
            return
        }
        if let baseTime = streamStartupBaseTimes[streamID],
           !streamStartupFirstPacketSent.contains(streamID) {
            streamStartupFirstPacketSent.insert(streamID)
            let deltaMs = Int((CFAbsoluteTimeGetCurrent() - baseTime) * 1000)
            MirageLogger.host("Desktop start: first video packet sent for stream \(streamID) (+\(deltaMs)ms)")
        }
        if let onComplete {
            connection.send(content: data, completion: .contentProcessed { _ in
                onComplete()
            })
        } else {
            connection.send(content: data, completion: .idempotent)
        }
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
