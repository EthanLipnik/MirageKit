//
//  MirageBootstrapIdentityVerification.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Minimal identity verification helpers for bootstrap daemon auth.
//

import CryptoKit
import Foundation

public enum MirageBootstrapIdentityVerification {
    public static func keyID(for publicKey: Data) -> String {
        let canonicalPublicKey = canonicalizedPublicKeyData(publicKey)
        let digest = SHA256.hash(data: canonicalPublicKey)
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }
        .joined()
    }

    public static func verify(signature: Data, payload: Data, publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return key.isValidSignature(parsed, for: payload)
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
