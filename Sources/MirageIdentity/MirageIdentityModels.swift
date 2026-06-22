//
//  MirageIdentityModels.swift
//  MirageIdentity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Stable Mirage peer identity.
public struct MiragePeerID: Sendable, Codable, Hashable {
    /// Stable device identity advertised by the peer.
    public let deviceID: UUID

    /// Optional app identity for catalog-synthesized peers.
    public let appID: String?

    /// Creates a peer identity.
    public init(deviceID: UUID, appID: String? = nil) {
        self.deviceID = deviceID
        self.appID = appID
    }
}

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

    /// Creates canonical identity details for a connected host.
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

    /// Host UUIDs that may identify this same authenticated host across discovery and bootstrap.
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

/// Trust and authorization state for an active or pending Mirage host connection.
public enum MirageAuthorizationState: String, Sendable, Codable, Equatable {
    /// No host authorization flow is active.
    case idle

    /// The client is evaluating the host identity.
    case verifyingTrust

    /// The host is waiting for manual trust approval.
    case awaitingManualApproval

    /// The current host identity is trusted.
    case approved
}
