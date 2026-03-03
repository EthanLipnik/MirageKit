//
//  MirageIdentityX963Tests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Regression coverage for canonical X9.63 identity keys.
//

import CryptoKit
import Foundation
@testable import MirageKit
import Testing

@Suite("Mirage Identity X9.63")
struct MirageIdentityX963Tests {
    @MainActor
    @Test("Current identity uses uncompressed X9.63 public key bytes")
    func currentIdentityUsesX963PublicKey() throws {
        let manager = makeIdentityManager()
        let identity = try manager.currentIdentity()

        #expect(identity.publicKey.count == 65)
        #expect(identity.publicKey.first == 0x04)
    }

    @MainActor
    @Test("Key IDs hash canonical X9.63 bytes")
    func keyIDUsesCanonicalX963Bytes() throws {
        let manager = makeIdentityManager()
        let identity = try manager.currentIdentity()

        let expected = sha256Hex(identity.publicKey)
        #expect(identity.keyID == expected)
        #expect(MirageIdentityManager.keyID(for: identity.publicKey) == expected)
    }

    @MainActor
    @Test("Signature verification accepts X9.63 and rejects legacy raw format")
    func signatureVerificationRequiresX963PublicKey() throws {
        let manager = makeIdentityManager()
        let payload = Data("mirage-signature-check".utf8)
        let signature = try manager.sign(payload)
        let identity = try manager.currentIdentity()

        #expect(MirageIdentityManager.verify(
            signature: signature,
            payload: payload,
            publicKey: identity.publicKey
        ))

        let legacyRawPublicKey = Data(identity.publicKey.dropFirst())
        #expect(!MirageIdentityManager.verify(
            signature: signature,
            payload: payload,
            publicKey: legacyRawPublicKey
        ))
    }

    @MainActor
    @Test("ECDH derivation accepts X9.63 peer public keys")
    func deriveSharedKeyAcceptsX963PeerPublicKey() throws {
        let manager = makeIdentityManager()
        let peerKey = P256.KeyAgreement.PrivateKey()
        let salt = Data("mirage-salt".utf8)
        let sharedInfo = Data("mirage-shared-info".utf8)

        let derivedKey = try manager.deriveSharedKey(
            with: peerKey.publicKey.x963Representation,
            salt: salt,
            sharedInfo: sharedInfo
        )
        #expect(derivedKey.count == 32)

        do {
            _ = try manager.deriveSharedKey(
                with: peerKey.publicKey.rawRepresentation,
                salt: salt,
                sharedInfo: sharedInfo
            )
            Issue.record("Expected non-X9.63 peer key derivation to fail.")
        } catch {
            // Expected invalid key encoding.
        }
    }

    @MainActor
    private func makeIdentityManager() -> MirageIdentityManager {
        MirageIdentityManager(
            service: "com.mirage.tests.identity.\(UUID().uuidString)",
            account: "p256-signing-\(UUID().uuidString)",
            synchronizable: false
        )
    }

    private func sha256Hex(_ value: Data) -> String {
        let digest = SHA256.hash(data: value)
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }
        .joined()
    }
}
