//
//  MirageBootstrapControlClient.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Client runtime for bootstrap daemon control handoff.
//

import Foundation
import Network

/// Control-channel runtime failures for daemon handoff.
public enum MirageBootstrapControlError: LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case timedOut
    case connectionFailed(String)
    case protocolViolation(String)
    case unlockRejected(String)

    /// A user-presentable reason for the failure.
    ///
    /// Prefer matching the enum case in code when you need deterministic behavior.
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Bootstrap control endpoint is invalid."
        case .timedOut:
            "Bootstrap control request timed out."
        case let .connectionFailed(detail):
            "Bootstrap control connection failed: \(detail)"
        case let .protocolViolation(detail):
            "Bootstrap control protocol error: \(detail)"
        case let .unlockRejected(detail):
            "Bootstrap daemon rejected unlock request: \(detail)"
        }
    }
}

/// Daemon handoff result.
public struct MirageBootstrapControlResult: Sendable, Equatable {
    /// Current host session state after control request.
    public let state: HostSessionState
    /// Optional host diagnostic message.
    public let message: String?
    /// Whether unlock reached an active session.
    public var isSessionActive: Bool { state == .active }

    /// Creates a daemon control result.
    ///
    /// - Parameters:
    ///   - state: Host session state observed by the daemon after processing the request.
    ///   - message: Optional host-provided diagnostic text suitable for logs or UI.
    public init(state: HostSessionState, message: String?) {
        self.state = state
        self.message = message
    }
}

/// Cross-platform client contract for daemon handoff and login completion.
public protocol MirageBootstrapControlClient: Sendable {
    /// Requests the daemon's current session state without attempting unlock.
    ///
    /// - Parameters:
    ///   - endpoint: Target endpoint selected from bootstrap metadata.
    ///   - controlPort: TCP port where the bootstrap daemon control server listens.
    ///   - timeout: End-to-end timeout for connect, request, and response.
    /// - Returns: Current daemon-observed host state and an optional message.
    /// - Throws: ``MirageBootstrapControlError`` when the request fails or times out.
    func requestStatus(
        endpoint: MirageBootstrapEndpoint,
        controlPort: UInt16,
        timeout: Duration
    ) async throws -> MirageBootstrapControlResult

    /// Requests unlock completion through the bootstrap daemon.
    ///
    /// Use this after an SSH pre-login step succeeds and the lock/login UI is present.
    ///
    /// - Parameters:
    ///   - endpoint: Target endpoint selected from bootstrap metadata.
    ///   - controlPort: TCP port where the bootstrap daemon control server listens.
    ///   - username: Optional username for login-window unlock flows.
    ///   - password: Account password used by host-side unlock logic.
    ///   - timeout: End-to-end timeout for connect, request, and response.
    /// - Returns: Updated host state and optional daemon message.
    /// - Throws: ``MirageBootstrapControlError`` for transport/protocol errors and rejected unlock attempts.
    func requestUnlock(
        endpoint: MirageBootstrapEndpoint,
        controlPort: UInt16,
        username: String?,
        password: String,
        timeout: Duration
    ) async throws -> MirageBootstrapControlResult
}

/// Default bootstrap control client based on a single line-delimited TCP request/response.
public struct MirageDefaultBootstrapControlClient: MirageBootstrapControlClient {
    /// Creates the default TCP line-delimited JSON control client.
    ///
    /// Example:
    /// ```swift
    /// let client = MirageDefaultBootstrapControlClient()
    /// let result = try await client.requestStatus(
    ///     endpoint: endpoint,
    ///     controlPort: 9849,
    ///     timeout: .seconds(2)
    /// )
    /// ```
    public init() {}

    /// Sends a `.status` control operation to the daemon.
    ///
    /// - Parameters:
    ///   - endpoint: Bootstrap endpoint chosen for control handoff.
    ///   - controlPort: Daemon control TCP port.
    ///   - timeout: Request timeout.
    /// - Returns: Current daemon-reported session state.
    public func requestStatus(
        endpoint: MirageBootstrapEndpoint,
        controlPort: UInt16,
        timeout: Duration
    )
    async throws -> MirageBootstrapControlResult {
        let request = MirageBootstrapControlRequest(
            operation: .status
        )
        let response = try await sendRequest(
            request,
            endpoint: endpoint,
            controlPort: controlPort,
            timeout: timeout
        )
        return MirageBootstrapControlResult(
            state: response.state,
            message: response.message
        )
    }

    /// Sends an `.unlock` control operation to the daemon.
    ///
    /// - Note: Newline-only passwords are rejected before any network request is sent.
    ///
    /// - Parameters:
    ///   - endpoint: Bootstrap endpoint chosen for control handoff.
    ///   - controlPort: Daemon control TCP port.
    ///   - username: Optional login user for multi-user login windows.
    ///   - password: Credential value sent to the daemon.
    ///   - timeout: Request timeout.
    /// - Returns: Updated daemon-reported state after unlock attempt.
    public func requestUnlock(
        endpoint: MirageBootstrapEndpoint,
        controlPort: UInt16,
        username: String?,
        password: String,
        timeout: Duration
    )
    async throws -> MirageBootstrapControlResult {
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        guard !trimmedPassword.isEmpty else {
            throw MirageBootstrapControlError.protocolViolation("Unlock password is empty.")
        }

        let request = MirageBootstrapControlRequest(
            operation: .unlock,
            username: username,
            password: trimmedPassword
        )
        let response = try await sendRequest(
            request,
            endpoint: endpoint,
            controlPort: controlPort,
            timeout: timeout
        )

        guard response.success else {
            throw MirageBootstrapControlError.unlockRejected(response.message ?? "Unlock rejected.")
        }

        return MirageBootstrapControlResult(
            state: response.state,
            message: response.message
        )
    }
}

private extension MirageDefaultBootstrapControlClient {
    func sendRequest(
        _ request: MirageBootstrapControlRequest,
        endpoint: MirageBootstrapEndpoint,
        controlPort: UInt16,
        timeout: Duration
    )
    async throws -> MirageBootstrapControlResponse {
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, controlPort > 0 else { throw MirageBootstrapControlError.invalidEndpoint }

        let timeoutNanoseconds = timeoutNanoseconds(timeout)
        guard timeoutNanoseconds > 0 else { throw MirageBootstrapControlError.timedOut }

        return try await withThrowingTaskGroup(of: MirageBootstrapControlResponse.self) { group in
            group.addTask {
                try await performRequest(
                    request,
                    host: host,
                    port: controlPort
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MirageBootstrapControlError.timedOut
            }

            guard let first = try await group.next() else {
                throw MirageBootstrapControlError.connectionFailed("Missing control response.")
            }
            group.cancelAll()
            return first
        }
    }

    func performRequest(
        _ request: MirageBootstrapControlRequest,
        host: String,
        port: UInt16
    ) async throws -> MirageBootstrapControlResponse {
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: .tcp
        )
        connection.start(queue: .global(qos: .utility))
        defer { connection.cancel() }

        try await awaitReady(connection)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        try await send(data: payload, over: connection)

        let line = try await receiveLine(over: connection, maxBytes: 32 * 1024)
        let response = try JSONDecoder().decode(MirageBootstrapControlResponse.self, from: line)
        guard response.requestID == request.requestID else {
            throw MirageBootstrapControlError.protocolViolation("Mismatched response request ID.")
        }
        return response
    }

    func awaitReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = ReadyContinuationBox(continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.complete(.success(()))
                case let .failed(error):
                    completion.complete(.failure(MirageBootstrapControlError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    completion.complete(.failure(MirageBootstrapControlError.connectionFailed("Connection cancelled.")))
                default:
                    break
                }
            }
        }
    }

    func send(data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MirageBootstrapControlError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func receiveLine(
        over connection: NWConnection,
        maxBytes: Int
    )
    async throws -> Data {
        var buffer = Data()
        while true {
            let chunk = try await receiveChunk(over: connection)
            if chunk.isEmpty {
                throw MirageBootstrapControlError.connectionFailed("Connection closed by daemon.")
            }
            buffer.append(chunk)

            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return buffer[..<newlineIndex]
            }

            if buffer.count > maxBytes {
                throw MirageBootstrapControlError.protocolViolation("Response exceeded \(maxBytes) bytes.")
            }
        }
    }

    func receiveChunk(over connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: MirageBootstrapControlError.connectionFailed(error.localizedDescription))
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

                continuation.resume(throwing: MirageBootstrapControlError.connectionFailed("No response data received."))
            }
        }
    }

    func timeoutNanoseconds(_ timeout: Duration) -> UInt64 {
        let components = timeout.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let secondNanos = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let fractionalNanos = UInt64(attoseconds / 1_000_000_000)
        if secondNanos.overflow {
            return UInt64.max
        }
        let total = secondNanos.partialValue.addingReportingOverflow(fractionalNanos)
        return total.overflow ? UInt64.max : total.partialValue
    }
}

private final class ReadyContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Void, Error>

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        switch result {
        case .success:
            continuation.resume(returning: ())
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
