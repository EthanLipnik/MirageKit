//
//  ConnectionManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Network
import MirageKit

/// Thread-safe completion flag for connection state handling
private final class CompletionFlag: @unchecked Sendable {
    private var _completed = false
    private let lock = NSLock()

    var completed: Bool {
        get { lock.withLock { _completed } }
        set { lock.withLock { _completed = newValue } }
    }

    func completeOnce() -> Bool {
        lock.withLock {
            if _completed { return false }
            _completed = true
            return true
        }
    }
}

/// Manages TCP control channel connections
actor ConnectionManager {
    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?

    private let queue = DispatchQueue(label: "com.mirage.connection", qos: .userInteractive)

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private(set) var state: State = .disconnected

    weak var delegate: ConnectionManagerDelegate?

    init() {}

    /// Connect to a host endpoint
    func connect(to endpoint: NWEndpoint, timeout: TimeInterval = 10) async throws {
        guard state == .disconnected else { throw MirageError.protocolError("Already connected or connecting") }

        state = .connecting

        let parameters = NWParameters.tcp
        parameters.serviceClass = .interactiveVideo

        // Enable TCP_NODELAY for low latency
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveInterval = 5
        }

        connection = NWConnection(to: endpoint, using: parameters)

        let completionFlag = CompletionFlag()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection?.stateUpdateHandler = { [weak self] newState in
                guard completionFlag.completeOnce() else { return }

                switch newState {
                case .ready:
                    Task { await self?.setState(.connected) }
                    continuation.resume()
                case let .failed(error):
                    Task { await self?.setState(.failed(error.localizedDescription)) }
                    continuation.resume(throwing: error)
                case .cancelled:
                    Task { await self?.setState(.disconnected) }
                    continuation.resume(throwing: MirageError.connectionFailed(CancellationError()))
                default:
                    // Reset flag since we didn't actually complete
                    completionFlag.completed = false
                }
            }

            connection?.start(queue: queue)

            // Timeout
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if completionFlag.completeOnce() {
                    await self?.connection?.cancel()
                    continuation.resume(throwing: MirageError.timeout)
                }
            }
        }

        // Start receiving messages
        startReceiving()
    }

    private func setState(_ newState: State) {
        state = newState
    }

    /// Disconnect from the current host
    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        state = .disconnected
    }

    /// Send a control message
    func send(_ message: ControlMessage) async throws {
        guard state == .connected, let connection else { throw MirageError.protocolError("Not connected") }

        let data = message.serialize()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Send a typed message
    func send(_ type: ControlMessageType, content: some Encodable) async throws {
        let message = try ControlMessage(type: type, content: content)
        try await send(message)
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        var buffer = Data()

        while state == .connected, let connection {
            do {
                let data = try await receive(connection: connection, minLength: 1, maxLength: 65536)
                buffer.append(data)

                // Process complete messages
                while let (message, consumed) = ControlMessage.deserialize(from: buffer) {
                    buffer.removeFirst(consumed)
                    await delegate?.connectionManager(self, didReceive: message)
                }
            } catch {
                if state == .connected {
                    state = .failed(error.localizedDescription)
                    await delegate?.connectionManager(self, didDisconnectWith: error)
                }
                break
            }
        }
    }

    private func receive(connection: NWConnection, minLength: Int, maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection
                .receive(
                    minimumIncompleteLength: minLength,
                    maximumLength: maxLength
                ) { content, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) } else if let data = content, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: MirageError.protocolError("Connection closed"))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
        }
    }
}

/// Delegate for connection events
protocol ConnectionManagerDelegate: AnyObject, Sendable {
    func connectionManager(_ manager: ConnectionManager, didReceive message: ControlMessage) async
    func connectionManager(_ manager: ConnectionManager, didDisconnectWith error: Error) async
}
