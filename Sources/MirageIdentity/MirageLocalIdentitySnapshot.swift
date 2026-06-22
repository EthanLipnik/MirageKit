//
//  MirageLocalIdentitySnapshot.swift
//  MirageIdentity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Mirage-owned snapshot of the local account identity advertised and used for authenticated handshakes.
public struct MirageLocalIdentitySnapshot: Sendable, Codable, Hashable {
    /// Stable key identifier derived from the local public identity key.
    public let keyID: String

    /// Public identity key bytes advertised to peers for signed handshakes and continuity checks.
    public let publicKey: Data

    /// Creates a local identity snapshot.
    public init(keyID: String, publicKey: Data) {
        self.keyID = keyID
        self.publicKey = publicKey
    }

    /// Whether this snapshot carries public key bytes in addition to the key identifier.
    public var hasPublicKey: Bool {
        !publicKey.isEmpty
    }

    /// Whether the key identifier matches the public key bytes in this snapshot.
    public var keyIDMatchesPublicKey: Bool {
        hasPublicKey && MirageIdentityKeyID.matches(keyID, publicKey: publicKey)
    }
}
