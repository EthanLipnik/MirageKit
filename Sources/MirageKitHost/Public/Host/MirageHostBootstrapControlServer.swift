//
//  MirageHostBootstrapControlServer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/21/26.
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
    private let controlAuthSecret: String
    private let replayProtector = LoomReplayProtector()
    private let queue = DispatchQueue(label: "com.mirage.bootstrap.control", qos: .userInitiated)
    private var listener: NWListener?

    public init(
        unlockService: MirageHostBootstrapUnlockService,
        controlAuthSecret: String
    ) {
        self.unlockService = unlockService
        self.controlAuthSecret = controlAuthSecret.trimmingCharacters(in: .whitespacesAndNewlines)
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
                MirageLogger.error(.bootstrapHandoff, error: error, message: "Bootstrap control listener failed: ")
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
            let requestLine = try await receiveLine(
                over: connection,
                maxBytes: LoomMessageLimits.maxBootstrapControlLineBytes
            )
            let request = try JSONDecoder().decode(LoomBootstrapControlRequest.self, from: requestLine)
            let response = await process(request: request)
            try await send(response: response, over: connection)

            if response.availability == .ready {
                stop()
            }
        } catch {
            MirageLogger.error(.bootstrapHandoff, error: error, message: "Bootstrap control request handling failed: ")
        }
    }

    private func process(request: LoomBootstrapControlRequest) async -> LoomBootstrapControlResponse {
        let state = await unlockService.currentState()

        guard !controlAuthSecret.isEmpty else {
            return LoomBootstrapControlResponse(
                requestID: request.requestID,
                success: false,
                availability: state,
                message: "Bootstrap control auth is unavailable on host.",
                canRetry: false,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )
        }

        let auth = request.auth

        guard auth.keyID == LoomIdentityManager.keyID(for: auth.publicKey) else {
            return unauthorizedResponse(state: state, requestID: request.requestID, detail: "Invalid auth key ID.")
        }

        let encryptedPayloadSHA256 = LoomBootstrapControlSecurity.payloadSHA256Hex(request.credentialsPayload?.combined)
        let canonicalPayload: Data
        do {
            canonicalPayload = try LoomBootstrapControlSecurity.canonicalPayload(
                requestID: request.requestID,
                operation: request.operation,
                encryptedPayloadSHA256: encryptedPayloadSHA256,
                keyID: auth.keyID,
                timestampMs: auth.timestampMs,
                nonce: auth.nonce
            )
        } catch {
            return unauthorizedResponse(state: state, requestID: request.requestID, detail: "Canonical payload failed.")
        }

        guard LoomIdentityManager.verify(
            signature: auth.signature,
            payload: canonicalPayload,
            publicKey: auth.publicKey
        ) else {
            return unauthorizedResponse(state: state, requestID: request.requestID, detail: "Invalid auth signature.")
        }

        let replayValid = await replayProtector.validate(
            timestampMs: auth.timestampMs,
            nonce: auth.nonce
        )
        guard replayValid else {
            return unauthorizedResponse(state: state, requestID: request.requestID, detail: "Replay protection rejected request.")
        }

        switch request.operation {
        case .status:
            return LoomBootstrapControlResponse(
                requestID: request.requestID,
                success: true,
                availability: state,
                message: "State probe complete.",
                canRetry: false,
                retriesRemaining: nil,
                retryAfterSeconds: nil
            )

        case .submitCredentials:
            guard let encryptedPayload = request.credentialsPayload else {
                return LoomBootstrapControlResponse(
                    requestID: request.requestID,
                    success: false,
                    availability: state,
                    message: "Missing encrypted unlock payload.",
                    canRetry: false,
                    retriesRemaining: nil,
                    retryAfterSeconds: nil
                )
            }
            if encryptedPayload.combined.count > LoomMessageLimits.maxBootstrapCredentialCiphertextBytes {
                return LoomBootstrapControlResponse(
                    requestID: request.requestID,
                    success: false,
                    availability: state,
                    message: "Encrypted unlock payload is too large.",
                    canRetry: false,
                    retriesRemaining: nil,
                    retryAfterSeconds: nil
                )
            }

            let credentials: LoomBootstrapCredentials
            do {
                credentials = try LoomBootstrapControlSecurity.decryptCredentials(
                    encryptedPayload,
                    sharedSecret: controlAuthSecret,
                    requestID: request.requestID,
                    timestampMs: auth.timestampMs,
                    nonce: auth.nonce
                )
            } catch {
                return LoomBootstrapControlResponse(
                    requestID: request.requestID,
                    success: false,
                    availability: state,
                    message: "Failed to decrypt unlock payload.",
                    canRetry: false,
                    retriesRemaining: nil,
                    retryAfterSeconds: nil
                )
            }

            let result = await unlockService.attemptUnlock(
                username: credentials.userIdentifier,
                password: credentials.secret
            )
            return LoomBootstrapControlResponse(
                requestID: request.requestID,
                success: result.success,
                availability: result.state,
                message: result.message,
                canRetry: result.canRetry,
                retriesRemaining: result.retriesRemaining,
                retryAfterSeconds: result.retryAfterSeconds
            )
        }
    }

    private func unauthorizedResponse(
        state: LoomSessionAvailability,
        requestID: UUID,
        detail: String
    ) -> LoomBootstrapControlResponse {
        LoomBootstrapControlResponse(
            requestID: requestID,
            success: false,
            availability: state,
            message: "Unauthorized bootstrap control request (\(detail))",
            canRetry: false,
            retriesRemaining: nil,
            retryAfterSeconds: nil
        )
    }

    private func send(response: LoomBootstrapControlResponse, over connection: NWConnection) async throws {
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
                return Data(buffer[..<newlineIndex])
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
