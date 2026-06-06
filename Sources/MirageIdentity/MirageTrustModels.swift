//
//  MirageTrustModels.swift
//  MirageIdentity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Product-safe authenticated peer identity used after a signed transport handshake.
public struct MirageAuthenticatedPeerIdentity: Sendable, Codable, Hashable {
    /// Stable Mirage peer identity.
    public let peerID: MiragePeerID

    /// Human-readable peer display name.
    public let displayName: String

    /// Broad peer device family, if known.
    public let deviceType: MirageDeviceType?

    /// iCloud user record identifier used by trust providers, if available.
    public let iCloudUserID: String?

    /// Optional signed identity key ID used for trust continuity.
    public let identityKeyID: String?

    /// Optional signed identity public key bytes.
    public let identityPublicKey: Data?

    /// Whether the peer identity was cryptographically authenticated.
    public let isIdentityAuthenticated: Bool

    /// Optional endpoint description captured during connection setup.
    public let endpointDescription: String?

    /// Creates an authenticated peer identity snapshot.
    public init(
        peerID: MiragePeerID,
        displayName: String,
        deviceType: MirageDeviceType? = nil,
        iCloudUserID: String? = nil,
        identityKeyID: String? = nil,
        identityPublicKey: Data? = nil,
        isIdentityAuthenticated: Bool,
        endpointDescription: String? = nil
    ) {
        self.peerID = peerID
        self.displayName = displayName
        self.deviceType = deviceType
        self.iCloudUserID = iCloudUserID
        self.identityKeyID = identityKeyID
        self.identityPublicKey = identityPublicKey
        self.isIdentityAuthenticated = isIdentityAuthenticated
        self.endpointDescription = endpointDescription
    }

    /// Creates an authenticated peer identity snapshot from device-level fields.
    public init(
        deviceID: UUID,
        appID: String? = nil,
        displayName: String,
        deviceType: MirageDeviceType? = nil,
        iCloudUserID: String? = nil,
        identityKeyID: String? = nil,
        identityPublicKey: Data? = nil,
        isIdentityAuthenticated: Bool,
        endpointDescription: String? = nil
    ) {
        self.init(
            peerID: MiragePeerID(deviceID: deviceID, appID: appID),
            displayName: displayName,
            deviceType: deviceType,
            iCloudUserID: iCloudUserID,
            identityKeyID: identityKeyID,
            identityPublicKey: identityPublicKey,
            isIdentityAuthenticated: isIdentityAuthenticated,
            endpointDescription: endpointDescription
        )
    }

    /// Stable device identifier for this peer.
    public var deviceID: UUID {
        peerID.deviceID
    }

    /// Whether the identity includes an authenticated key pair suitable for continuity checks.
    public var hasAuthenticatedIdentityKey: Bool {
        isIdentityAuthenticated && identityKeyID != nil && identityPublicKey != nil
    }

    /// Whether the authenticated identity key fields are present and internally consistent.
    public var hasConsistentAuthenticatedIdentityKey: Bool {
        guard isIdentityAuthenticated,
              let identityKeyID,
              let identityPublicKey else {
            return false
        }
        return MirageIdentityKeyID.matches(identityKeyID, publicKey: identityPublicKey)
    }
}

/// Mirage-owned trust decision used by product policy.
public enum MirageTrustDecision: String, Sendable, Codable, Equatable, CaseIterable {
    /// Peer is trusted without further approval.
    case trusted

    /// Manual approval is required before the peer is trusted.
    case requiresApproval

    /// Peer was denied by the trust provider.
    case denied

    /// Trust provider was unavailable or could not evaluate the peer.
    case unavailable

    /// Whether the decision authorizes trusted-only product actions.
    public var isTrusted: Bool {
        self == .trusted
    }
}

/// Product-safe trust evaluation metadata used after transport trust mechanics complete.
public struct MirageTrustEvaluationSnapshot: Sendable, Codable, Equatable {
    /// Final trust decision projected into Mirage-owned terms.
    public let decision: MirageTrustDecision

    /// Whether callers should present a one-time automatic trust notice.
    public let shouldShowAutoTrustNotice: Bool

    /// Optional unavailable-provider detail when the decision is `.unavailable`.
    public let unavailabilityReason: String?

    /// Creates a trust evaluation snapshot.
    public init(
        decision: MirageTrustDecision,
        shouldShowAutoTrustNotice: Bool,
        unavailabilityReason: String? = nil
    ) {
        self.decision = decision
        self.shouldShowAutoTrustNotice = shouldShowAutoTrustNotice
        self.unavailabilityReason = decision == .unavailable ? unavailabilityReason : nil
    }

    /// Whether this evaluation authorizes trusted-only busy-host takeover.
    public var authorizesBusyHostTakeover: Bool {
        decision.isTrusted
    }
}

/// Product trust-provider boundary that evaluates authenticated Mirage peer identities.
public protocol MirageTrustProvider: AnyObject, Sendable {
    /// Evaluates whether to trust a connecting peer.
    @MainActor
    func evaluateTrust(for peer: MirageAuthenticatedPeerIdentity) async -> MirageTrustDecision

    /// Evaluates trust plus caller-facing notice metadata for a connecting peer.
    @MainActor
    func evaluateTrustOutcome(for peer: MirageAuthenticatedPeerIdentity) async -> MirageTrustEvaluationSnapshot

    /// Grants trust to a peer, persisting the decision when supported by the provider.
    @MainActor
    func grantTrust(to peer: MirageAuthenticatedPeerIdentity) async throws

    /// Revokes previously granted trust for a peer.
    @MainActor
    func revokeTrust(for peerID: MiragePeerID) async throws
}

public extension MirageTrustProvider {
    /// Default trust outcome adapter built from ``evaluateTrust(for:)``.
    @MainActor
    func evaluateTrustOutcome(for peer: MirageAuthenticatedPeerIdentity) async -> MirageTrustEvaluationSnapshot {
        let decision = await evaluateTrust(for: peer)
        return MirageTrustEvaluationSnapshot(
            decision: decision,
            shouldShowAutoTrustNotice: decision == .trusted
        )
    }
}
