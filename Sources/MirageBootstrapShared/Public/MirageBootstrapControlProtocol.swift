//
//  MirageBootstrapControlProtocol.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Authenticated line-based JSON protocol used for host bootstrap daemon handoff.
//

import CryptoKit
import Foundation

public enum MirageBootstrapControlOperation: String, Codable, Sendable {
    case status
    case unlock
}

public struct MirageBootstrapControlAuthEnvelope: Codable, Sendable, Equatable {
    public let keyID: String
    public let publicKey: Data
    public let timestampMs: Int64
    public let nonce: String
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

public struct MirageBootstrapEncryptedUnlockPayload: Codable, Sendable, Equatable {
    public let combined: Data

    public init(combined: Data) {
        self.combined = combined
    }
}

public struct MirageBootstrapControlRequest: Codable, Sendable {
    public let requestID: UUID
    public let operation: MirageBootstrapControlOperation
    public let auth: MirageBootstrapControlAuthEnvelope
    public let encryptedUnlockPayload: MirageBootstrapEncryptedUnlockPayload?

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

public struct MirageBootstrapControlResponse: Codable, Sendable {
    public let requestID: UUID
    public let success: Bool
    public let state: HostSessionState
    public let message: String?
    public let canRetry: Bool
    public let retriesRemaining: Int?
    public let retryAfterSeconds: Int?

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

public struct MirageBootstrapUnlockCredentials: Codable, Sendable, Equatable {
    public let username: String?
    public let password: String

    public init(username: String?, password: String) {
        self.username = username
        self.password = password
    }
}

public enum MirageBootstrapControlProtocolError: LocalizedError, Sendable {
    case emptySharedSecret
    case nonceTooLong
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .emptySharedSecret:
            "Bootstrap control secret is empty"
        case .nonceTooLong:
            "Bootstrap control nonce is too long"
        case .invalidPayload:
            "Bootstrap control payload is invalid"
        }
    }
}

public enum MirageBootstrapControlSecurity {
    private static let keyContext = Data("mirage-bootstrap-control".utf8)

    public static func canonicalPayload(
        requestID: UUID,
        operation: MirageBootstrapControlOperation,
        encryptedPayloadSHA256: String,
        keyID: String,
        timestampMs: Int64,
        nonce: String
    ) throws -> Data {
        try canonicalData([
            ("type", "bootstrap-control"),
            ("requestID", requestID.uuidString.lowercased()),
            ("operation", operation.rawValue),
            ("encryptedPayloadSHA256", encryptedPayloadSHA256),
            ("keyID", keyID),
            ("timestampMs", "\(timestampMs)"),
            ("nonce", nonce),
        ])
    }

    public static func payloadSHA256Hex(_ data: Data?) -> String {
        let digest = SHA256.hash(data: data ?? Data("-".utf8))
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }
        .joined()
    }

    public static func encryptUnlockCredentials(
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

    public static func decryptUnlockCredentials(
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
            throw MirageBootstrapControlProtocolError.emptySharedSecret
        }
        guard nonce.utf8.count <= MirageControlMessageLimits.maxReplayNonceLength else {
            throw MirageBootstrapControlProtocolError.nonceTooLong
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

    private static func canonicalData(_ fields: [(String, String)]) throws -> Data {
        let text = fields
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "\n")
        guard let data = text.data(using: .utf8) else {
            throw MirageBootstrapControlProtocolError.invalidPayload
        }
        return data
    }
}
