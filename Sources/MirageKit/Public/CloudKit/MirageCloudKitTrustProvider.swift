//
//  MirageCloudKitTrustProvider.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  iCloud-based trust provider for automatic device approval.
//

import Foundation

/// iCloud-based trust provider that auto-approves devices on the same iCloud account
/// or devices belonging to friends via CloudKit sharing.
///
/// This provider implements a layered trust evaluation:
///
/// 1. If ``requireApprovalForAllConnections`` is enabled → `.requiresApproval`
/// 2. If device is in the local trust store → `.trusted`
/// 3. If peer has no iCloud identity → `.requiresApproval`
/// 4. If CloudKit is unavailable → `.unavailable`
/// 5. If peer is on same iCloud account → `.trusted`
/// 6. If peer is a share participant (friend) → `.trusted`
/// 7. Otherwise → `.requiresApproval`
///
/// ## Usage
///
/// ```swift
/// let cloudKitManager = MirageCloudKitManager(
///     containerIdentifier: "iCloud.com.yourcompany.YourApp"
/// )
/// let trustProvider = MirageCloudKitTrustProvider(
///     cloudKitManager: cloudKitManager,
///     localTrustStore: trustStore
/// )
/// hostService.trustProvider = trustProvider
/// ```
@MainActor
public final class MirageCloudKitTrustProvider: MirageTrustProvider {
    // MARK: - Properties

    /// CloudKit manager for user identity and share checking.
    private let cloudKitManager: MirageCloudKitManager

    /// Local trust store fallback for devices without iCloud.
    private let localTrustStore: MirageTrustStore

    /// Whether to require approval for all connections regardless of iCloud status.
    ///
    /// When enabled, even devices on the same iCloud account or share participants
    /// will require manual approval. Use this for high-security scenarios.
    public var requireApprovalForAllConnections: Bool = false

    // MARK: - Initialization

    /// Creates a CloudKit-based trust provider.
    ///
    /// - Parameters:
    ///   - cloudKitManager: The CloudKit manager for identity and share checking.
    ///   - localTrustStore: Local trust store for manually approved devices.
    public init(cloudKitManager: MirageCloudKitManager, localTrustStore: MirageTrustStore) {
        self.cloudKitManager = cloudKitManager
        self.localTrustStore = localTrustStore
    }

    // MARK: - MirageTrustProvider

    public nonisolated func evaluateTrust(for peer: MiragePeerIdentity) async -> MirageTrustDecision {
        await evaluateTrustOnMain(for: peer)
    }

    @MainActor
    private func evaluateTrustOnMain(for peer: MiragePeerIdentity) async -> MirageTrustDecision {
        // Check settings override first
        if requireApprovalForAllConnections {
            MirageLogger.appState("Trust evaluation: approval required by settings for \(peer.name)")
            return .requiresApproval
        }

        guard peer.isIdentityAuthenticated else {
            MirageLogger.appState("Trust evaluation: denied unauthenticated identity for \(peer.name)")
            return .denied
        }
        guard let peerIdentityKeyID = peer.identityKeyID else {
            MirageLogger.appState("Trust evaluation: denied missing identity key ID for \(peer.name)")
            return .denied
        }
        if let publicKey = peer.identityPublicKey,
           MirageIdentityManager.keyID(for: publicKey) != peerIdentityKeyID {
            MirageLogger.appState("Trust evaluation: denied mismatched key ID for \(peer.name)")
            return .denied
        }

        // Check if locally trusted (overrides everything)
        if localTrustStore.isTrusted(deviceID: peer.deviceID) {
            MirageLogger.appState("Trust evaluation: device \(peer.name) is locally trusted")
            return .trusted
        }

        // No iCloud identity means we can't auto-trust
        guard let peerUserID = peer.iCloudUserID else {
            MirageLogger.appState("Trust evaluation: no iCloud identity for \(peer.name)")
            return .requiresApproval
        }

        // Check if CloudKit is available
        guard cloudKitManager.isAvailable else {
            MirageLogger.appState("Trust evaluation: CloudKit unavailable, falling back to approval")
            return .unavailable("iCloud not available")
        }

        // Check if same iCloud account
        if let myUserID = cloudKitManager.currentUserRecordID, peerUserID == myUserID {
            MirageLogger.appState("Trust evaluation: same iCloud account for \(peer.name)")
            return .trusted
        }

        // Check if peer is a share participant (friend)
        let isParticipant = await cloudKitManager.isShareParticipant(userID: peerUserID)
        if isParticipant {
            let identityTrusted = await cloudKitManager.isShareParticipantIdentityKeyTrusted(keyID: peerIdentityKeyID)
            if identityTrusted {
                MirageLogger.appState("Trust evaluation: share participant identity trusted for \(peer.name)")
                return .trusted
            }
            MirageLogger.appState("Trust evaluation: share participant missing trusted identity key for \(peer.name)")
            return .requiresApproval
        }

        // Unknown user - require approval
        MirageLogger.appState("Trust evaluation: unknown iCloud user, requiring approval for \(peer.name)")
        return .requiresApproval
    }

    public nonisolated func grantTrust(to peer: MiragePeerIdentity) async throws {
        await MainActor.run {
            // Add to local trust store
            let device = MirageTrustedDevice(
                id: peer.deviceID,
                name: peer.name,
                deviceType: peer.deviceType,
                trustedAt: Date()
            )
            localTrustStore.addTrustedDevice(device)
            MirageLogger.appState("Granted trust to \(peer.name)")
        }
    }

    public nonisolated func revokeTrust(for deviceID: UUID) async throws {
        await MainActor.run {
            if let device = localTrustStore.trustedDevices.first(where: { $0.id == deviceID }) {
                localTrustStore.revokeTrust(for: device)
                MirageLogger.appState("Revoked trust for device \(deviceID)")
            }
        }
    }
}
