//
//  MirageHostBootstrapControlServer.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Bootstrap daemon TCP control listener for status/unlock requests.
//

import Foundation
import MirageKit
import Network

#if os(macOS)

public enum MirageHostBootstrapControlServerError: LocalizedError, Sendable {
    case invalidPort
    case listenerFailed(String)
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort:
            "Bootstrap control server port is invalid."
        case let .listenerFailed(detail):
            "Bootstrap control listener failed: \(detail)"
        case let .protocolViolation(detail):
            "Bootstrap control protocol violation: \(detail)"
        }
    }
}

/// Host-side control server used by the pre-login bootstrap daemon.
public actor MirageHostBootstrapControlServer {
    private let unlockService: MirageHostBootstrapUnlockService
    private let queue = DispatchQueue(label: "com.mirage.bootstrap.control", qos: .userInitiated)
    private var listener: NWListener?

    public init(unlockService: MirageHostBootstrapUnlockService) {
        self.unlockService = unlockService
    }

    public func start(port: UInt16) async throws {
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MirageHostBootstrapControlServerError.invalidPort
        }
        if listener != nil { return }

        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleConnection(connection)
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                MirageLogger.bootstrapHandoff("Bootstrap control server listening on \(port)")
            case let .failed(error):
                MirageLogger.error(.bootstrapHandoff, "Bootstrap control listener failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: queue)
        defer { connection.cancel() }

        do {
            let requestLine = try await receiveLine(over: connection, maxBytes: 64 * 1024)
            let request = try JSONDecoder().decode(MirageBootstrapControlRequest.self, from: requestLine)
            let response = await process(request: request)
            try await send(response: response, over: connection)

            if response.state == .active {
                stop()
            }
        } catch {
            MirageLogger.error(.bootstrapHandoff, "Bootstrap control request handling failed: \(error.localizedDescription)")
        }
    }

    private func process(request: MirageBootstrapControlRequest) async -> MirageBootstrapControlResponse {
        if request.version != 1 {
            let state = await unlockService.currentState()
            return MirageBootstrapControlResponse(
                version: 1,
                requestID: request.requestID,
                success: false,
                state: state,
                message: "Unsupported control protocol version \(request.version).",
                canRetry: false,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )
        }

        switch request.operation {
        case .status:
            let state = await unlockService.currentState()
            return MirageBootstrapControlResponse(
                version: 1,
                requestID: request.requestID,
                success: true,
                state: state,
                message: "State probe complete.",
                canRetry: false,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )

        case .unlock:
            let result = await unlockService.attemptUnlock(
                username: request.username,
                password: request.password ?? ""
            )
            return MirageBootstrapControlResponse(
                version: 1,
                requestID: request.requestID,
                success: result.success,
                state: result.state,
                message: result.message,
                canRetry: result.canRetry,
                retriesRemaining: result.retriesRemaining,
                retryAfterSeconds: result.retryAfterSeconds
            )
        }
    }

    private func send(response: MirageBootstrapControlResponse, over connection: NWConnection) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var payload = try encoder.encode(response)
        payload.append(0x0A)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MirageHostBootstrapControlServerError.listenerFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func receiveLine(
        over connection: NWConnection,
        maxBytes: Int
    )
    async throws -> Data {
        var buffer = Data()
        while true {
            let chunk = try await receiveChunk(over: connection)
            if chunk.isEmpty {
                throw MirageHostBootstrapControlServerError.protocolViolation("Connection closed before request line was received.")
            }
            buffer.append(chunk)

            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return buffer[..<newlineIndex]
            }

            if buffer.count > maxBytes {
                throw MirageHostBootstrapControlServerError.protocolViolation("Request exceeded \(maxBytes) bytes.")
            }
        }
    }

    private func receiveChunk(over connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: MirageHostBootstrapControlServerError.listenerFailed(error.localizedDescription))
                    return
                }
                if let data {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(
                    throwing: MirageHostBootstrapControlServerError.protocolViolation("Missing request payload.")
                )
            }
        }
    }
}

#endif
