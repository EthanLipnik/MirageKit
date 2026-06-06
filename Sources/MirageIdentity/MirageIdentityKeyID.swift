//
//  MirageIdentityKeyID.swift
//  MirageIdentity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CryptoKit
import Foundation

/// Mirage identity key identifier derivation.
public enum MirageIdentityKeyID {
    /// Computes the stable key identifier for a public identity key.
    ///
    /// Valid P-256 signing keys are canonicalized before hashing. Invalid bytes are still mapped to
    /// a deterministic sentinel hash so diagnostics and compatibility checks remain stable.
    public static func keyID(for publicKey: Data) -> String {
        let canonicalPublicKey = canonicalizedPublicKeyData(publicKey)
        let digest = SHA256.hash(data: canonicalPublicKey)
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }
        .joined()
    }

    /// Returns whether a key identifier matches the supplied public identity key.
    public static func matches(_ keyID: String, publicKey: Data) -> Bool {
        self.keyID(for: publicKey) == keyID
    }

    private static func canonicalizedPublicKeyData(_ publicKey: Data) -> Data {
        guard let parsed = try? P256.Signing.PublicKey(x963Representation: publicKey) else {
            var invalidSentinel = Data("invalid-p256-x963:".utf8)
            invalidSentinel.append(publicKey)
            return invalidSentinel
        }
        return parsed.x963Representation
    }
}
