//
//  MirageBootstrapControlClient.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  Client runtime for bootstrap daemon control handoff.
//

import Foundation
import Network

/// Control-channel runtime failures for daemon handoff.
public enum MirageBootstrapControlError: LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case missingAuthSecret
    case timedOut
    case connectionFailed(String)
    case protocolViolation(String)
    case unlockRejected(String)

    /// A user-presentable reason for the failure.
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Bootstrap control endpoint is invalid."
        case .missingAuthSecret:
            "Bootstrap control requires an auth secret from host metadata."
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

    public init(state: HostSessionState, message: String?) {
        self.state = state
        self.message = message
    }
}

/// Cross-platform client contract for daemon handoff and login completion.
public protocol MirageBootstrapControlClient: Sendable {
    func requestStatus(
        endpoint: MirageBootstrapEndpoint,
        controlPort: UInt16,
        controlAuthSecret: String,
        timeout: Duration
    ) async throws -> MirageBootstrapControlResult

    func requestUnlock(
        endpoint: MirageBootstrapEndpoint,
        controlPort: UInt16,
        controlAuthSecret: String,
        username: String?,
        password: String,
        timeout: Duration
    ) async throws -> MirageBootstrapControlResult
}

/// Default bootstrap control client based on a single line-delimited TCP request/response.
public struct MirageDefaultBootstrapControlClient: MirageBootstrapControlClient {
    public init() {}

    public func requestStatus(
        endpoint: MirageBootstrapEndpoint,
        controlPort: UInt16,
        controlAuthSecret: String,
        timeout: Duration
    )
    async throws -> MirageBootstrapControlResult {
        let request = try await makeAuthenticatedRequest(
            operation: .status,
            controlAuthSecret: controlAuthSecret,
            encryptedUnlockPayload: nil
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

    public func requestUnlock(
        endpoint: MirageBootstrapEndpoint,
        controlPort: UInt16,
        controlAuthSecret: String,
        username: String?,
        password: String,
        timeout: Duration
    )
    async throws -> MirageBootstrapControlResult {
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        guard !trimmedPassword.isEmpty else {
            throw MirageBootstrapControlError.protocolViolation("Unlock password is empty.")
        }

        let requestID = UUID()
        let timestampMs = MirageIdentitySigning.currentTimestampMs()
        let nonce = UUID().uuidString.lowercased()
        let credentials = MirageBootstrapUnlockCredentials(
            username: username,
            password: trimmedPassword
        )
        let encryptedPayload = try MirageBootstrapControlSecurity.encryptUnlockCredentials(
            credentials,
            sharedSecret: controlAuthSecret,
            requestID: requestID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let request = try await makeAuthenticatedRequest(
            operation: .unlock,
            controlAuthSecret: controlAuthSecret,
            encryptedUnlockPayload: encryptedPayload,
            requestID: requestID,
            timestampMs: timestampMs,
            nonce: nonce
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
    func makeAuthenticatedRequest(
        operation: MirageBootstrapControlOperation,
        controlAuthSecret: String,
        encryptedUnlockPayload: MirageBootstrapEncryptedUnlockPayload?,
        requestID: UUID = UUID(),
        timestampMs: Int64 = MirageIdentitySigning.currentTimestampMs(),
        nonce: String = UUID().uuidString.lowercased()
    ) async throws -> MirageBootstrapControlRequest {
        let trimmedSecret = controlAuthSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty else {
            throw MirageBootstrapControlError.missingAuthSecret
        }
        guard nonce.utf8.count <= MirageControlMessageLimits.maxReplayNonceLength else {
            throw MirageBootstrapControlError.protocolViolation("Bootstrap control nonce is too long.")
        }

        let identity = try await MainActor.run {
            try MirageIdentityManager.shared.currentIdentity()
        }
        let encryptedSHA256 = MirageBootstrapControlSecurity.payloadSHA256Hex(encryptedUnlockPayload?.combined)
        let payload = try MirageBootstrapControlSecurity.canonicalPayload(
            requestID: requestID,
            operation: operation,
            encryptedPayloadSHA256: encryptedSHA256,
            keyID: identity.keyID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let signature = try await MainActor.run {
            try MirageIdentityManager.shared.sign(payload)
        }
        let auth = MirageBootstrapControlAuthEnvelope(
            keyID: identity.keyID,
            publicKey: identity.publicKey,
            timestampMs: timestampMs,
            nonce: nonce,
            signature: signature
        )

        return MirageBootstrapControlRequest(
            requestID: requestID,
            operation: operation,
            auth: auth,
            encryptedUnlockPayload: encryptedUnlockPayload
        )
    }

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

        let line = try await receiveLine(
            over: connection,
            maxBytes: MirageControlMessageLimits.maxBootstrapControlLineBytes
        )
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
                return Data(buffer[..<newlineIndex])
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
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
