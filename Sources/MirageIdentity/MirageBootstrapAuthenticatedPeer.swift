//
//  MirageBootstrapAuthenticatedPeer.swift
//  MirageIdentity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Authenticated peer key material established by an out-of-band Mirage bootstrap control channel.
public struct MirageBootstrapAuthenticatedPeer: Sendable, Codable, Hashable {
    /// Authenticated peer identity key identifier.
    public let keyID: String

    /// Authenticated peer public identity key bytes.
    public let publicKey: Data

    /// Endpoint description observed by the bootstrap control channel.
    public let endpointDescription: String

    /// Creates an authenticated bootstrap peer snapshot.
    public init(
        keyID: String,
        publicKey: Data,
        endpointDescription: String
    ) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.endpointDescription = endpointDescription
    }

    /// Whether the authenticated key ID matches the authenticated public key bytes.
    public var keyIDMatchesPublicKey: Bool {
        MirageIdentityKeyID.matches(keyID, publicKey: publicKey)
    }
}
