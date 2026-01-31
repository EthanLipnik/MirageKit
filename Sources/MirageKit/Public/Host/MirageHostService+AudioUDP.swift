//
//  MirageHostService+AudioUDP.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/30/26.
//
//  Audio UDP listener and registration handling.
//

import Foundation
import Network

#if os(macOS)
@MainActor
extension MirageHostService {
    func startAudioListener() async throws -> UInt16 {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = networkConfig.enablePeerToPeer

        let port: NWEndpoint.Port = networkConfig.audioPort == 0 ? .any : NWEndpoint.Port(rawValue: networkConfig.audioPort) ?? .any

        let listener = try NWListener(using: params, on: port)
        self.audioListener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInteractive))
            Task { @MainActor [weak self] in
                await self?.handleIncomingAudioConnection(connection)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ContinuationBox<UInt16>(continuation)

            listener.stateUpdateHandler = { [continuationBox] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        continuationBox.resume(returning: port)
                    }
                case .failed(let error):
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

    /// Handle an incoming UDP connection from a client (for audio data).
    func handleIncomingAudioConnection(_ connection: NWConnection) async {
        while true {
            let result: (Data?, NWConnection.ContentContext?, Bool, NWError?) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 20, maximumLength: 64) { data, context, isComplete, error in
                    continuation.resume(returning: (data, context, isComplete, error))
                }
            }

            if let error = result.3 {
                MirageLogger.host("Audio UDP connection error: \(error)")
                break
            }

            guard let data = result.0, data.count >= 20 else {
                if result.2 {
                    MirageLogger.host("Audio UDP connection closed (no more data)")
                    break
                }
                MirageLogger.host("Invalid audio registration packet")
                continue
            }

            let magic = data.prefix(4)
            guard magic.elementsEqual([0x4D, 0x49, 0x52, 0x41]) else {
                MirageLogger.host("Invalid audio registration magic")
                continue
            }

            let uuidTuple = data.dropFirst(4).prefix(16).withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: 0, as: uuid_t.self)
            }
            let deviceID = UUID(uuid: uuidTuple)

            guard let entry = clientsByConnection.first(where: { $0.value.client.id == deviceID }) else {
                MirageLogger.host("Audio registration from unknown device \(deviceID.uuidString)")
                continue
            }

            let connectionID = entry.key
            var context = entry.value
            context.audioConnection = connection
            clientsByConnection[connectionID] = context
            audioConnectionByClientID[deviceID] = connection
            activeAudioClientID = deviceID

            MirageLogger.host("Audio UDP connection registered for client \(deviceID.uuidString)")
        }
    }
}
#endif
