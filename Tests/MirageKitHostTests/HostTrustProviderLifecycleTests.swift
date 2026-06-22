//
//  HostTrustProviderLifecycleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//

@testable import MirageKitHost
import Loom
import MirageIdentity
import Foundation
import Testing

#if os(macOS)
@MainActor
@Suite("Host Trust Provider Lifecycle")
struct HostTrustProviderLifecycleTests {
    @Test("Host service owner must retain trust providers assigned through the weak boundary")
    func hostServiceOwnerMustRetainTrustProviders() {
        let host = MirageHostService()
        weak var weakProvider: RecordingTrustProvider?

        do {
            let provider = RecordingTrustProvider(decision: .trusted)
            weakProvider = provider
            host.trustProvider = provider

            #expect(host.trustProvider != nil)
            #expect(host.loomNode.trustProvider != nil)
        }

        #expect(weakProvider == nil)
        #expect(host.trustProvider == nil)
        #expect(host.loomNode.trustProvider == nil)
    }

    @Test("Retained trust provider remains callable through host service wiring")
    func retainedTrustProviderRemainsCallableThroughHostServiceWiring() async {
        let host = MirageHostService()
        let provider = RecordingTrustProvider(decision: .trusted)
        host.trustProvider = provider

        let peer = LoomPeerIdentity(
            deviceID: UUID(),
            name: "Altair",
            deviceType: .mac,
            iCloudUserID: nil,
            identityKeyID: "client-key",
            identityPublicKey: nil,
            isIdentityAuthenticated: true,
            endpoint: "127.0.0.1"
        )

        let evaluation = await host.loomNode.trustProvider?.evaluateTrustOutcome(for: peer)

        #expect(evaluation?.decision == .trusted)
        #expect(provider.evaluatedPeers == [peer])
    }

    @Test("Mirage trust provider bridges into Loom handshake wiring")
    func mirageTrustProviderBridgesIntoLoomHandshakeWiring() async throws {
        let host = MirageHostService()
        let provider = RecordingMirageTrustProvider(
            evaluation: MirageTrustEvaluationSnapshot(
                decision: .unavailable,
                shouldShowAutoTrustNotice: false,
                unavailabilityReason: "offline"
            )
        )
        host.mirageTrustProvider = provider

        let deviceID = UUID()
        let publicKey = Data([0x01, 0x02])
        let peer = LoomPeerIdentity(
            deviceID: deviceID,
            name: "Altair",
            deviceType: .iPad,
            iCloudUserID: "icloud-user",
            identityKeyID: "client-key",
            identityPublicKey: publicKey,
            isIdentityAuthenticated: true,
            endpoint: "127.0.0.1"
        )

        let evaluation = await host.loomNode.trustProvider?.evaluateTrustOutcome(for: peer)
        try await host.loomNode.trustProvider?.grantTrust(to: peer)
        try await host.loomNode.trustProvider?.revokeTrust(for: deviceID)

        #expect(evaluation?.decision == .unavailable("offline"))
        #expect(evaluation?.shouldShowAutoTrustNotice == false)
        let evaluatedPeer = try #require(provider.evaluatedPeers.first)
        #expect(evaluatedPeer.deviceID == deviceID)
        #expect(evaluatedPeer.displayName == "Altair")
        #expect(evaluatedPeer.iCloudUserID == "icloud-user")
        #expect(evaluatedPeer.identityKeyID == "client-key")
        #expect(evaluatedPeer.identityPublicKey == publicKey)
        #expect(evaluatedPeer.isIdentityAuthenticated)
        #expect(evaluatedPeer.endpointDescription == "127.0.0.1")
        #expect(provider.grantedPeers.map(\.deviceID) == [deviceID])
        #expect(provider.revokedPeerIDs == [MiragePeerID(deviceID: deviceID)])
    }
}

@MainActor
private final class RecordingTrustProvider: LoomTrustProvider {
    let decision: LoomTrustDecision
    private(set) var evaluatedPeers: [LoomPeerIdentity] = []

    init(decision: LoomTrustDecision) {
        self.decision = decision
    }

    func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
        evaluatedPeers.append(peer)
        return decision
    }

    func evaluateTrustOutcome(for peer: LoomPeerIdentity) async -> LoomTrustEvaluation {
        evaluatedPeers.append(peer)
        return LoomTrustEvaluation(decision: decision, shouldShowAutoTrustNotice: false)
    }

    func grantTrust(to peer: LoomPeerIdentity) async throws {
        evaluatedPeers.append(peer)
    }

    func revokeTrust(for _: UUID) async throws {}
}

@MainActor
private final class RecordingMirageTrustProvider: MirageTrustProvider {
    let evaluation: MirageTrustEvaluationSnapshot
    private(set) var evaluatedPeers: [MirageAuthenticatedPeerIdentity] = []
    private(set) var grantedPeers: [MirageAuthenticatedPeerIdentity] = []
    private(set) var revokedPeerIDs: [MiragePeerID] = []

    init(evaluation: MirageTrustEvaluationSnapshot) {
        self.evaluation = evaluation
    }

    func evaluateTrust(for peer: MirageAuthenticatedPeerIdentity) async -> MirageTrustDecision {
        evaluatedPeers.append(peer)
        return evaluation.decision
    }

    func evaluateTrustOutcome(for peer: MirageAuthenticatedPeerIdentity) async -> MirageTrustEvaluationSnapshot {
        evaluatedPeers.append(peer)
        return evaluation
    }

    func grantTrust(to peer: MirageAuthenticatedPeerIdentity) async throws {
        grantedPeers.append(peer)
    }

    func revokeTrust(for peerID: MiragePeerID) async throws {
        revokedPeerIDs.append(peerID)
    }
}
#endif
