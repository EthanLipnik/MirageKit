//
//  MirageTrustProvider.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Protocol for custom trust resolution in connection approval flows.
//

import Foundation

// MARK: - Trust Decision

/// Result of trust evaluation for a connecting peer.
public enum MirageTrustDecision: Sendable, Equatable {
    /// Auto-approve connection without prompting user.
    case trusted

    /// Show manual approval prompt to user.
    case requiresApproval

    /// Reject connection immediately.
    case denied

    /// Trust provider is offline or encountered an error; fall back to manual approval.
    case unavailable(String)

    public static func == (lhs: MirageTrustDecision, rhs: MirageTrustDecision) -> Bool {
        switch (lhs, rhs) {
        case (.trusted, .trusted): true
        case (.requiresApproval, .requiresApproval): true
        case (.denied, .denied): true
        case let (.unavailable(a), .unavailable(b)): a == b
        default: false
        }
    }
}

// MARK: - Peer Identity

/// Extended device identity with optional iCloud information.
///
/// Contains all identifying information about a connecting peer, including
/// the optional iCloud user ID for same-account and friend-share trust evaluation.
public struct MiragePeerIdentity: Sendable {
    /// Unique device identifier.
    public let deviceID: UUID

    /// Display name of the device.
    public let name: String

    /// Type of device (Mac, iPad, iPhone, Vision).
    public let deviceType: DeviceType

    /// iCloud user record ID (CKRecord.ID.recordName), if available.
    /// Used to determine if the peer is on the same iCloud account or is a share participant.
    public let iCloudUserID: String?

    /// Network endpoint description (IP address or hostname).
    public let endpoint: String

    public init(
        deviceID: UUID,
        name: String,
        deviceType: DeviceType,
        iCloudUserID: String?,
        endpoint: String
    ) {
        self.deviceID = deviceID
        self.name = name
        self.deviceType = deviceType
        self.iCloudUserID = iCloudUserID
        self.endpoint = endpoint
    }
}

// MARK: - Trust Provider Protocol

/// Protocol for custom trust resolution during connection approval.
///
/// Implement this protocol to provide custom logic for determining whether
/// to auto-trust, prompt for approval, or deny incoming connections.
///
/// The default behavior when no provider is set is to use delegate-based
/// manual approval for all connections.
///
/// Example implementation for iCloud-based trust:
/// ```swift
/// class CloudKitTrustProvider: MirageTrustProvider {
///     func evaluateTrust(for peer: MiragePeerIdentity) async -> MirageTrustDecision {
///         guard let peerUserID = peer.iCloudUserID else {
///             return .requiresApproval
///         }
///         if peerUserID == myUserID {
///             return .trusted  // Same iCloud account
///         }
///         if isShareParticipant(userID: peerUserID) {
///             return .trusted  // Friend with share access
///         }
///         return .requiresApproval
///     }
/// }
/// ```
public protocol MirageTrustProvider: AnyObject, Sendable {
    /// Evaluates whether to trust a connecting peer.
    ///
    /// - Parameter peer: Identity information about the connecting device.
    /// - Returns: Decision on how to handle the connection.
    @MainActor
    func evaluateTrust(for peer: MiragePeerIdentity) async -> MirageTrustDecision

    /// Grants trust to a peer, persisting the decision.
    ///
    /// Called when the user manually approves a connection with "Always Trust" option.
    /// The provider should persist this trust decision for future connections.
    ///
    /// - Parameter peer: Identity of the peer to trust.
    @MainActor
    func grantTrust(to peer: MiragePeerIdentity) async throws

    /// Revokes previously granted trust for a device.
    ///
    /// - Parameter deviceID: Identifier of the device to revoke trust for.
    @MainActor
    func revokeTrust(for deviceID: UUID) async throws
}
