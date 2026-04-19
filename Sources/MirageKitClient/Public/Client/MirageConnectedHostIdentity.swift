//
//  MirageConnectedHostIdentity.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/19/26.
//

import Foundation

/// Canonical identity details for the currently connected host.
public struct MirageConnectedHostIdentity: Equatable, Sendable {
    /// Authenticated host identifier returned by Mirage bootstrap.
    public let acceptedHostID: UUID

    /// Authenticated host identity key ID validated by Loom.
    public let identityKeyID: String

    /// Device identifier from the provisional discovery peer used to connect.
    public let provisionalHostID: UUID?

    /// Device identifier advertised by the provisional discovery peer, if present.
    public let advertisedHostID: UUID?

    public init(
        acceptedHostID: UUID,
        identityKeyID: String,
        provisionalHostID: UUID? = nil,
        advertisedHostID: UUID? = nil
    ) {
        self.acceptedHostID = acceptedHostID
        self.identityKeyID = identityKeyID
        self.provisionalHostID = provisionalHostID
        self.advertisedHostID = advertisedHostID
    }

    public var uuidAliases: Set<UUID> {
        var aliases: Set<UUID> = [acceptedHostID]
        if let provisionalHostID {
            aliases.insert(provisionalHostID)
        }
        if let advertisedHostID {
            aliases.insert(advertisedHostID)
        }
        return aliases
    }
}
