//
//  HostTrustProviderLifecycleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//

@testable import MirageKitHost
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

    func revokeTrust(for deviceID: UUID) async throws {}
}
#endif
