//
//  HybridTransport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Network

/// Thread-safe completion flag for connection state handling
private final class TransportCompletionFlag: @unchecked Sendable {
    private var _completed = false
    private let lock = NSLock()

    func completeOnce() -> Bool {
        lock.withLock {
            if _completed { return false }
            _completed = true
            return true
        }
    }
}

/// Hybrid UDP+TCP transport for video streaming
/// TCP: Control messages (reliable)
/// UDP: Video frames (low latency)
actor HybridTransport {
    private var controlConnection: NWConnection?
    private var dataConnection: NWConnection?

    private let queue = DispatchQueue(label: "com.mirage.transport", qos: .userInteractive)

    enum State {
        case disconnected
        case connecting
        case connected
        case failed(Error)
    }

    private(set) var state: State = .disconnected

    /// Callback for received video packets
    var onVideoPacket: (@Sendable (Data, FrameHeader) -> Void)?

    /// Callback for control messages
    var onControlMessage: (@Sendable (ControlMessage) -> Void)?

    /// Connect to a host
    func connect(
        controlEndpoint: NWEndpoint,
        dataHost: NWEndpoint.Host,
        dataPort: NWEndpoint.Port
    ) async throws {
        state = .connecting

        // TCP Control Connection
        let tcpParams = NWParameters.tcp
        tcpParams.serviceClass = .interactiveVideo

        if let tcpOptions = tcpParams.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveInterval = 5
        }

        controlConnection = NWConnection(to: controlEndpoint, using: tcpParams)

        // UDP Data Connection
        let udpParams = NWParameters.udp
        udpParams.serviceClass = .interactiveVideo
        udpParams.allowLocalEndpointReuse = true

        let dataEndpoint = NWEndpoint.hostPort(host: dataHost, port: dataPort)
        dataConnection = NWConnection(to: dataEndpoint, using: udpParams)

        // Start both connections
        async let tcpReady: Void = waitForReady(controlConnection!, name: "TCP")
        async let udpReady: Void = waitForReady(dataConnection!, name: "UDP")

        try await tcpReady
        try await udpReady

        state = .connected

        // Start receive loops
        Task { await receiveControlLoop() }
        Task { await receiveDataLoop() }
    }

    private func waitForReady(_ connection: NWConnection, name: String) async throws {
        let completionFlag = TransportCompletionFlag()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if completionFlag.completeOnce() {
                        continuation.resume()
                    }
                case .failed(let error):
                    if completionFlag.completeOnce() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if completionFlag.completeOnce() {
                        continuation.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    /// Set the control message handler
    func setControlMessageHandler(_ handler: @escaping @Sendable (ControlMessage) -> Void) {
        onControlMessage = handler
    }

    /// Set the video packet handler
    func setVideoPacketHandler(_ handler: @escaping @Sendable (Data, FrameHeader) -> Void) {
        onVideoPacket = handler
    }

    /// Disconnect both channels
    func disconnect() {
        controlConnection?.cancel()
        dataConnection?.cancel()
        controlConnection = nil
        dataConnection = nil
        state = .disconnected
    }

    // MARK: - Sending

    /// Send a control message over TCP
    func sendControl(_ message: ControlMessage) async throws {
        guard case .connected = state, let connection = controlConnection else {
            throw MirageError.protocolError("Not connected")
        }

        let data = message.serialize()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Send video packets over UDP
    func sendVideoPackets(_ packets: [Data]) async {
        guard case .connected = state, let connection = dataConnection else { return }

        for packet in packets {
            connection.send(content: packet, completion: .idempotent)
        }
    }

    /// Send a single video packet
    func sendVideoPacket(_ data: Data) {
        guard case .connected = state, let connection = dataConnection else { return }
        connection.send(content: data, completion: .idempotent)
    }

    // MARK: - Receiving

    private func receiveControlLoop() async {
        var buffer = Data()

        while case .connected = state, let connection = controlConnection {
            do {
                let data = try await receiveData(from: connection, min: 1, max: 65536)
                buffer.append(data)

                while let (message, consumed) = ControlMessage.deserialize(from: buffer) {
                    buffer.removeFirst(consumed)
                    onControlMessage?(message)
                }
            } catch {
                if case .connected = state {
                    state = .failed(error)
                }
                break
            }
        }
    }

    private func receiveDataLoop() async {
        while case .connected = state, let connection = dataConnection {
            do {
                let data = try await receiveData(from: connection, min: MirageHeaderSize, max: 65536)

                // Parse header
                guard let header = FrameHeader.deserialize(from: data) else {
                    continue
                }

                // Extract payload
                let payload = data.dropFirst(MirageHeaderSize)
                onVideoPacket?(Data(payload), header)
            } catch {
                if case .connected = state {
                    state = .failed(error)
                }
                break
            }
        }
    }

    private func receiveData(from connection: NWConnection, min: Int, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: min, maximumLength: max) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data = content, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: MirageError.protocolError("Connection closed"))
                } else {
                    // Empty data, try again
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    // MARK: - Statistics

    struct TransportStatistics {
        var bytesSent: UInt64 = 0
        var bytesReceived: UInt64 = 0
        var packetsSent: UInt64 = 0
        var packetsReceived: UInt64 = 0
    }

    private var statistics = TransportStatistics()

    func getStatistics() -> TransportStatistics {
        statistics
    }
}
