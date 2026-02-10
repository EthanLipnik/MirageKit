//
//  MirageIdentityManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Account-scoped signing identity backed by Keychain-synchronized P256 keys.
//

import CryptoKit
import Foundation
import Security

/// Public identity metadata for Mirage authenticated handshakes.
public struct MirageAccountIdentity: Sendable, Equatable {
    /// Stable key identifier derived from the public key digest.
    public let keyID: String

    /// Raw representation of the signing public key.
    public let publicKey: Data

    public init(keyID: String, publicKey: Data) {
        self.keyID = keyID
        self.publicKey = publicKey
    }
}

/// Manages the account signing key used by Mirage handshake and API request signatures.
///
/// The key is stored in Keychain with synchronization enabled so it propagates
/// across the user's iCloud Keychain environment.
@MainActor
public final class MirageIdentityManager {
    public static let shared = MirageIdentityManager()

    private let service: String
    private let account: String
    private let synchronizable: Bool
    private var cachedPrivateKey: P256.Signing.PrivateKey?
    private var cachedIdentity: MirageAccountIdentity?

    /// Creates an identity manager.
    ///
    /// - Parameters:
    ///   - service: Keychain service name.
    ///   - account: Keychain account key.
    ///   - synchronizable: Whether to enable iCloud Keychain sync.
    public init(
        service: String = "com.mirage.identity.account.v2",
        account: String = "p256-signing",
        synchronizable: Bool = true
    ) {
        self.service = service
        self.account = account
        self.synchronizable = synchronizable
    }

    /// Returns the active account identity, creating one when missing.
    public func currentIdentity() throws -> MirageAccountIdentity {
        if let cachedIdentity { return cachedIdentity }
        let key = try loadOrCreatePrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        let identity = MirageAccountIdentity(
            keyID: Self.keyID(for: publicKey),
            publicKey: publicKey
        )
        cachedIdentity = identity
        return identity
    }

    /// Signs a payload with the current account key.
    ///
    /// - Parameter payload: Canonical bytes to sign.
    /// - Returns: DER-encoded ECDSA signature bytes.
    public func sign(_ payload: Data) throws -> Data {
        let key = try loadOrCreatePrivateKey()
        let signature = try key.signature(for: payload)
        return signature.derRepresentation
    }

    /// Rotates the account signing key and returns the new identity.
    public func rotateIdentity() throws -> MirageAccountIdentity {
        try deletePrivateKey()
        cachedPrivateKey = nil
        cachedIdentity = nil
        return try currentIdentity()
    }

    /// Verifies a signature against a payload and raw public key bytes.
    ///
    /// - Returns: `true` when the signature is valid.
    public nonisolated static func verify(signature: Data, payload: Data, publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(rawRepresentation: publicKey),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return key.isValidSignature(parsed, for: payload)
    }

    /// Computes a stable key identifier from the provided public key.
    public nonisolated static func keyID(for publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }
        .joined()
    }

    // MARK: - Keychain

    private func loadOrCreatePrivateKey() throws -> P256.Signing.PrivateKey {
        if let cachedPrivateKey { return cachedPrivateKey }

        if let existing = try loadPrivateKey() {
            cachedPrivateKey = existing
            return existing
        }

        let created = P256.Signing.PrivateKey()
        try savePrivateKey(created)
        cachedPrivateKey = created
        return created
    }

    private func loadPrivateKey() throws -> P256.Signing.PrivateKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw MirageIdentityError.keychainReadFailed(status: status)
        }
        guard let data = item as? Data else {
            throw MirageIdentityError.invalidKeyData
        }

        do {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            throw MirageIdentityError.invalidKeyData
        }
    }

    private func savePrivateKey(_ key: P256.Signing.PrivateKey) throws {
        let data = key.rawRepresentation
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        attributes[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecAttrSynchronizable as String: (synchronizable ? kCFBooleanTrue : kCFBooleanFalse) as Any,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw MirageIdentityError.keychainWriteFailed(status: updateStatus)
            }
            return
        }
        throw MirageIdentityError.keychainWriteFailed(status: status)
    }

    private func deletePrivateKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MirageIdentityError.keychainDeleteFailed(status: status)
        }
    }
}

/// Identity manager failures.
public enum MirageIdentityError: LocalizedError, Sendable {
    case keychainReadFailed(status: OSStatus)
    case keychainWriteFailed(status: OSStatus)
    case keychainDeleteFailed(status: OSStatus)
    case invalidKeyData

    public var errorDescription: String? {
        switch self {
        case let .keychainReadFailed(status):
            "Failed to read identity key from Keychain (status: \(status))"
        case let .keychainWriteFailed(status):
            "Failed to write identity key to Keychain (status: \(status))"
        case let .keychainDeleteFailed(status):
            "Failed to delete identity key from Keychain (status: \(status))"
        case .invalidKeyData:
            "Identity key data is invalid"
        }
    }
}
