//
//  MirageIdentityTests.swift
//  MirageIdentity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import CryptoKit
import MirageIdentity
import Testing

@Suite("MirageIdentity")
struct MirageIdentityTests {
    @Test("Peer IDs preserve device and app identity")
    func peerIDsPreserveDeviceAndAppIdentity() throws {
        let deviceID = try #require(UUID(uuidString: "60000000-0000-0000-0000-000000000001"))
        let peerID = MiragePeerID(deviceID: deviceID, appID: "com.example.MirageHost")
        let decoded = try JSONDecoder().decode(
            MiragePeerID.self,
            from: try JSONEncoder().encode(peerID)
        )

        #expect(decoded == peerID)
        #expect(decoded.deviceID == deviceID)
        #expect(decoded.appID == "com.example.MirageHost")
    }

    @Test("Connected host identities expose all UUID aliases")
    func connectedHostIdentitiesExposeAllUUIDAliases() throws {
        let acceptedHostID = try #require(UUID(uuidString: "60000000-0000-0000-0000-000000000002"))
        let provisionalHostID = try #require(UUID(uuidString: "60000000-0000-0000-0000-000000000003"))
        let advertisedHostID = try #require(UUID(uuidString: "60000000-0000-0000-0000-000000000004"))
        let identity = MirageIdentity.MirageConnectedHostIdentity(
            acceptedHostID: acceptedHostID,
            identityKeyID: "identity-key",
            provisionalHostID: provisionalHostID,
            advertisedHostID: advertisedHostID
        )

        #expect(identity.identityKeyID == "identity-key")
        #expect(identity.uuidAliases == [acceptedHostID, provisionalHostID, advertisedHostID])
    }

    @Test("Local identity snapshots preserve advertised key material")
    func localIdentitySnapshotsPreserveAdvertisedKeyMaterial() throws {
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let snapshot = MirageLocalIdentitySnapshot(
            keyID: MirageIdentityKeyID.keyID(for: publicKey),
            publicKey: publicKey
        )
        let decoded = try JSONDecoder().decode(
            MirageLocalIdentitySnapshot.self,
            from: try JSONEncoder().encode(snapshot)
        )
        let emptyKeySnapshot = MirageLocalIdentitySnapshot(
            keyID: "identity-key",
            publicKey: Data()
        )

        #expect(decoded == snapshot)
        #expect(snapshot.hasPublicKey)
        #expect(snapshot.keyIDMatchesPublicKey)
        #expect(!emptyKeySnapshot.hasPublicKey)
        #expect(!emptyKeySnapshot.keyIDMatchesPublicKey)
    }

    @Test("Bootstrap authenticated peers preserve key material")
    func bootstrapAuthenticatedPeersPreserveKeyMaterial() throws {
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let peer = MirageBootstrapAuthenticatedPeer(
            keyID: MirageIdentityKeyID.keyID(for: publicKey),
            publicKey: publicKey,
            endpointDescription: "127.0.0.1"
        )
        let decoded = try JSONDecoder().decode(
            MirageBootstrapAuthenticatedPeer.self,
            from: try JSONEncoder().encode(peer)
        )

        #expect(decoded == peer)
        #expect(peer.keyIDMatchesPublicKey)
        #expect(peer.endpointDescription == "127.0.0.1")
    }

    @Test("Authorization states preserve trust flow wire names")
    func authorizationStatesPreserveTrustFlowWireNames() throws {
        let states: [MirageAuthorizationState] = [
            .idle,
            .verifyingTrust,
            .awaitingManualApproval,
            .approved,
        ]

        #expect(states.map(\.rawValue) == [
            "idle",
            "verifyingTrust",
            "awaitingManualApproval",
            "approved",
        ])
        for state in states {
            let decoded = try JSONDecoder().decode(
                MirageAuthorizationState.self,
                from: try JSONEncoder().encode(state)
            )
            #expect(decoded == state)
        }
    }

    @Test("Authenticated peer identities preserve trust continuity fields")
    func authenticatedPeerIdentitiesPreserveTrustContinuityFields() throws {
        let deviceID = try #require(UUID(uuidString: "60000000-0000-0000-0000-000000000005"))
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let identity = MirageAuthenticatedPeerIdentity(
            deviceID: deviceID,
            appID: "com.example.Mirage",
            displayName: "Studio iPad",
            deviceType: .iPad,
            iCloudUserID: "icloud-user",
            identityKeyID: MirageIdentityKeyID.keyID(for: publicKey),
            identityPublicKey: publicKey,
            isIdentityAuthenticated: true,
            endpointDescription: "127.0.0.1"
        )

        let decoded = try JSONDecoder().decode(
            MirageAuthenticatedPeerIdentity.self,
            from: try JSONEncoder().encode(identity)
        )

        #expect(decoded == identity)
        #expect(decoded.deviceID == deviceID)
        #expect(decoded.peerID.appID == "com.example.Mirage")
        #expect(decoded.deviceType == .iPad)
        #expect(decoded.hasAuthenticatedIdentityKey)
        #expect(decoded.hasConsistentAuthenticatedIdentityKey)
        #expect(MirageIdentity.MirageDeviceType.allCases.map(\.rawValue) == ["mac", "iPad", "iPhone", "vision", "unknown"])
        #expect(MirageIdentity.MirageDeviceType.allCases.map(\.displayName) == [
            "Mac",
            "iPad",
            "iPhone",
            "Apple Vision Pro",
            "Unknown",
        ])
        #expect(MirageIdentity.MirageDeviceType.allCases.map(\.systemImage) == [
            "desktopcomputer",
            "ipad",
            "iphone",
            "visionpro",
            "questionmark.circle",
        ])
        #expect(
            !MirageAuthenticatedPeerIdentity(
                deviceID: deviceID,
                displayName: "Studio iPad",
                identityKeyID: "mismatch",
                identityPublicKey: publicKey,
                isIdentityAuthenticated: true
            ).hasConsistentAuthenticatedIdentityKey
        )
    }

    @Test("Identity key IDs are deterministic for valid and invalid public keys")
    func identityKeyIDsAreDeterministicForValidAndInvalidPublicKeys() {
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let invalidPublicKey = Data([0x01, 0x02, 0x03])
        let keyID = MirageIdentityKeyID.keyID(for: publicKey)
        let invalidKeyID = MirageIdentityKeyID.keyID(for: invalidPublicKey)

        #expect(keyID == MirageIdentityKeyID.keyID(for: publicKey))
        #expect(invalidKeyID == MirageIdentityKeyID.keyID(for: invalidPublicKey))
        #expect(keyID.count == 64)
        #expect(invalidKeyID.count == 64)
        #expect(MirageIdentityKeyID.matches(keyID, publicKey: publicKey))
        #expect(!MirageIdentityKeyID.matches(keyID, publicKey: invalidPublicKey))
    }

    @Test("Trust evaluation snapshots preserve product trust decisions")
    func trustEvaluationSnapshotsPreserveProductTrustDecisions() throws {
        let unavailable = MirageTrustEvaluationSnapshot(
            decision: .unavailable,
            shouldShowAutoTrustNotice: false,
            unavailabilityReason: "offline"
        )
        let trusted = MirageTrustEvaluationSnapshot(
            decision: .trusted,
            shouldShowAutoTrustNotice: true,
            unavailabilityReason: "ignored"
        )

        let decoded = try JSONDecoder().decode(
            MirageTrustEvaluationSnapshot.self,
            from: try JSONEncoder().encode(unavailable)
        )

        #expect(MirageTrustDecision.allCases.map(\.rawValue) == [
            "trusted",
            "requiresApproval",
            "denied",
            "unavailable",
        ])
        #expect(decoded == unavailable)
        #expect(unavailable.unavailabilityReason == "offline")
        #expect(!unavailable.authorizesBusyHostTakeover)
        #expect(trusted.authorizesBusyHostTakeover)
        #expect(trusted.shouldShowAutoTrustNotice)
        #expect(trusted.unavailabilityReason == nil)
    }

    @MainActor
    @Test("Trust providers derive default evaluation snapshots")
    func trustProvidersDeriveDefaultEvaluationSnapshots() async throws {
        let deviceID = try #require(UUID(uuidString: "60000000-0000-0000-0000-000000000006"))
        let peer = MirageAuthenticatedPeerIdentity(
            deviceID: deviceID,
            displayName: "Studio iPad",
            identityKeyID: "identity-key",
            identityPublicKey: Data([0x01]),
            isIdentityAuthenticated: true
        )
        let provider = RecordingMirageTrustProvider(decision: .trusted)

        let evaluation = await provider.evaluateTrustOutcome(for: peer)

        #expect(evaluation.decision == .trusted)
        #expect(evaluation.shouldShowAutoTrustNotice)
        #expect(provider.evaluatedPeers == [peer])
    }

    @Test("Identity configuration preserves service and CloudKit names")
    func identityConfigurationPreservesServiceAndCloudKitNames() throws {
        #expect(MirageIdentityConfiguration.identityService == "com.mirage.identity.account.v2")
        #expect(MirageIdentityConfiguration.sharedDeviceIDKey == "com.mirage.shared.deviceID")
        #expect(MirageIdentityConfiguration.sharedDeviceIDSuiteName == "group.com.ethanlipnik.Mirage")
        #expect(MirageIdentityConfiguration.cloudKitDeviceRecordType == "MirageDevice")
        #expect(MirageIdentityConfiguration.cloudKitPeerRecordType == "MiragePeer")
        #expect(MirageIdentityConfiguration.cloudKitPeerZoneName == "MiragePeerZone")
        #expect(MirageIdentityConfiguration.cloudKitParticipantIdentityRecordType == "MirageParticipantIdentity")

        let sharedDeviceConfiguration = MirageIdentityConfiguration.sharedDeviceIDConfiguration
        let cloudKitConfiguration = MirageIdentityConfiguration.cloudKitIdentityConfiguration(
            containerIdentifier: "iCloud.com.example.Mirage"
        )
        let decodedConfiguration = try JSONDecoder().decode(
            MirageCloudKitIdentityConfiguration.self,
            from: try JSONEncoder().encode(cloudKitConfiguration)
        )

        #expect(sharedDeviceConfiguration.key == MirageIdentityConfiguration.sharedDeviceIDKey)
        #expect(sharedDeviceConfiguration.suiteName == MirageIdentityConfiguration.sharedDeviceIDSuiteName)
        #expect(cloudKitConfiguration.containerIdentifier == "iCloud.com.example.Mirage")
        #expect(cloudKitConfiguration.deviceRecordType == MirageIdentityConfiguration.cloudKitDeviceRecordType)
        #expect(cloudKitConfiguration.peerRecordType == MirageIdentityConfiguration.cloudKitPeerRecordType)
        #expect(cloudKitConfiguration.peerZoneName == MirageIdentityConfiguration.cloudKitPeerZoneName)
        #expect(
            cloudKitConfiguration.participantIdentityRecordType ==
                MirageIdentityConfiguration.cloudKitParticipantIdentityRecordType
        )
        #expect(cloudKitConfiguration.sharedDeviceIDConfiguration == sharedDeviceConfiguration)
        #expect(decodedConfiguration == cloudKitConfiguration)
    }
}

@MainActor
private final class RecordingMirageTrustProvider: MirageTrustProvider {
    let decision: MirageTrustDecision
    private(set) var evaluatedPeers: [MirageAuthenticatedPeerIdentity] = []

    init(decision: MirageTrustDecision) {
        self.decision = decision
    }

    func evaluateTrust(for peer: MirageAuthenticatedPeerIdentity) async -> MirageTrustDecision {
        evaluatedPeers.append(peer)
        return decision
    }

    func grantTrust(to _: MirageAuthenticatedPeerIdentity) async throws {}

    func revokeTrust(for _: MiragePeerID) async throws {}
}
