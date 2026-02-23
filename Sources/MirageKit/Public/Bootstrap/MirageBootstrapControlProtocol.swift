//
//  MirageBootstrapControlProtocol.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Authenticated line-based JSON protocol used for host bootstrap daemon handoff.
//

import CryptoKit
import Foundation

/// Bootstrap control operation kind.
public enum MirageBootstrapControlOperation: String, Codable, Sendable {
    case status
    case unlock
}

/// Signed bootstrap control request envelope.
public struct MirageBootstrapControlAuthEnvelope: Codable, Sendable, Equatable {
    /// Identity key identifier for the signing key.
    public let keyID: String
    /// Raw P-256 signing public key.
    public let publicKey: Data
    /// Millisecond timestamp used for replay protection.
    public let timestampMs: Int64
    /// Per-request nonce.
    public let nonce: String
    /// DER-encoded signature over canonical request bytes.
    public let signature: Data

    public init(
        keyID: String,
        publicKey: Data,
        timestampMs: Int64,
        nonce: String,
        signature: Data
    ) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.timestampMs = timestampMs
        self.nonce = nonce
        self.signature = signature
    }
}

/// Encrypted unlock credentials payload for bootstrap control.
public struct MirageBootstrapEncryptedUnlockPayload: Codable, Sendable, Equatable {
    /// ChaCha20-Poly1305 combined payload (`ciphertext + auth tag + nonce` wrapper omitted).
    public let combined: Data

    public init(combined: Data) {
        self.combined = combined
    }
}

/// Bootstrap control request payload sent to host bootstrap daemon.
public struct MirageBootstrapControlRequest: Codable, Sendable {
    /// Correlation identifier for request/response matching.
    public let requestID: UUID
    /// Operation to execute.
    public let operation: MirageBootstrapControlOperation
    /// Signed request authentication envelope.
    public let auth: MirageBootstrapControlAuthEnvelope
    /// Encrypted credentials payload for unlock operations.
    public let encryptedUnlockPayload: MirageBootstrapEncryptedUnlockPayload?

    /// Creates a bootstrap daemon control request payload.
    public init(
        requestID: UUID = UUID(),
        operation: MirageBootstrapControlOperation,
        auth: MirageBootstrapControlAuthEnvelope,
        encryptedUnlockPayload: MirageBootstrapEncryptedUnlockPayload? = nil
    ) {
        self.requestID = requestID
        self.operation = operation
        self.auth = auth
        self.encryptedUnlockPayload = encryptedUnlockPayload
    }
}

/// Bootstrap control response payload returned by host bootstrap daemon.
public struct MirageBootstrapControlResponse: Codable, Sendable {
    /// Correlation identifier for request/response matching.
    public let requestID: UUID
    /// Whether the requested operation succeeded.
    public let success: Bool
    /// Session state observed after operation.
    public let state: HostSessionState
    /// Human-readable message for diagnostics and remediation.
    public let message: String?
    /// Whether the request can be retried.
    public let canRetry: Bool
    /// Remaining retries available (if bounded by host policy).
    public let retriesRemaining: Int?
    /// Cooldown before retry is allowed.
    public let retryAfterSeconds: Int?

    /// Creates a daemon control response payload.
    public init(
        requestID: UUID,
        success: Bool,
        state: HostSessionState,
        message: String?,
        canRetry: Bool,
        retriesRemaining: Int?,
        retryAfterSeconds: Int?
    ) {
        self.requestID = requestID
        self.success = success
        self.state = state
        self.message = message
        self.canRetry = canRetry
        self.retriesRemaining = retriesRemaining
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// Decrypted unlock credentials for daemon unlock requests.
public struct MirageBootstrapUnlockCredentials: Codable, Sendable, Equatable {
    public let username: String?
    public let password: String

    public init(username: String?, password: String) {
        self.username = username
        self.password = password
    }
}

package enum MirageBootstrapControlSecurity {
    private static let keyContext = Data("mirage-bootstrap-control".utf8)

    package static func canonicalPayload(
        requestID: UUID,
        operation: MirageBootstrapControlOperation,
        encryptedPayloadSHA256: String,
        keyID: String,
        timestampMs: Int64,
        nonce: String
    ) throws -> Data {
        try MirageIdentitySigning.bootstrapControlPayload(
            requestID: requestID,
            operationRawValue: operation.rawValue,
            encryptedPayloadSHA256: encryptedPayloadSHA256,
            keyID: keyID,
            timestampMs: timestampMs,
            nonce: nonce
        )
    }

    package static func payloadSHA256Hex(_ data: Data?) -> String {
        let digest = SHA256.hash(data: data ?? Data("-".utf8))
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }
        .joined()
    }

    package static func encryptUnlockCredentials(
        _ credentials: MirageBootstrapUnlockCredentials,
        sharedSecret: String,
        requestID: UUID,
        timestampMs: Int64,
        nonce: String
    ) throws -> MirageBootstrapEncryptedUnlockPayload {
        let plaintext = try JSONEncoder().encode(credentials)
        let key = try deriveEncryptionKey(
            sharedSecret: sharedSecret,
            requestID: requestID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let sealed = try ChaChaPoly.seal(plaintext, using: key)
        return MirageBootstrapEncryptedUnlockPayload(combined: sealed.combined)
    }

    package static func decryptUnlockCredentials(
        _ payload: MirageBootstrapEncryptedUnlockPayload,
        sharedSecret: String,
        requestID: UUID,
        timestampMs: Int64,
        nonce: String
    ) throws -> MirageBootstrapUnlockCredentials {
        let key = try deriveEncryptionKey(
            sharedSecret: sharedSecret,
            requestID: requestID,
            timestampMs: timestampMs,
            nonce: nonce
        )
        let sealed = try ChaChaPoly.SealedBox(combined: payload.combined)
        let plaintext = try ChaChaPoly.open(sealed, using: key)
        return try JSONDecoder().decode(MirageBootstrapUnlockCredentials.self, from: plaintext)
    }

    private static func deriveEncryptionKey(
        sharedSecret: String,
        requestID: UUID,
        timestampMs: Int64,
        nonce: String
    ) throws -> SymmetricKey {
        let trimmedSecret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty else {
            throw MirageError.protocolError("Bootstrap control secret is empty")
        }
        guard nonce.utf8.count <= MirageControlMessageLimits.maxReplayNonceLength else {
            throw MirageError.protocolError("Bootstrap control nonce is too long")
        }

        let secretData = Data(trimmedSecret.utf8)
        let saltText = "\(requestID.uuidString.lowercased())|\(timestampMs)|\(nonce)"
        let salt = Data(SHA256.hash(data: Data(saltText.utf8)))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secretData),
            salt: salt,
            info: keyContext,
            outputByteCount: 32
        )
    }
}
