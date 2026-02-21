//
//  HostMediaEncryptionPolicyTests.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Coverage for host-side media encryption policy and local peer classification.
//

@testable import MirageKit
@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("Host Media Encryption Policy")
struct HostMediaEncryptionPolicyTests {
    @Test("Local network host classification follows private and link-local ranges")
    func localNetworkHostClassification() {
        #expect(ClientContext.isLocalNetworkHost("192.168.1.40"))
        #expect(ClientContext.isLocalNetworkHost("10.0.2.15"))
        #expect(ClientContext.isLocalNetworkHost("172.16.4.2"))
        #expect(ClientContext.isLocalNetworkHost("172.31.255.255"))
        #expect(ClientContext.isLocalNetworkHost("169.254.1.9"))
        #expect(ClientContext.isLocalNetworkHost("studio-mac.local"))
        #expect(ClientContext.isLocalNetworkHost("fe80::1"))

        #expect(!ClientContext.isLocalNetworkHost("172.32.0.1"))
        #expect(!ClientContext.isLocalNetworkHost("8.8.8.8"))
        #expect(!ClientContext.isLocalNetworkHost("2001:4860:4860::8888"))
        #expect(!ClientContext.isLocalNetworkHost("example.com"))
    }

    @MainActor
    @Test("Default host policy allows unencrypted media only on peer sessions")
    func defaultHostPolicyAllowsUnencryptedOnlyOnPeerSessions() {
        let host = MirageHostService()

        #expect(!host.mediaEncryptionEnabledForAcceptedSession(isPeerToPeer: true))
        #expect(host.mediaEncryptionEnabledForAcceptedSession(isPeerToPeer: false))
    }

    @MainActor
    @Test("Local-unencrypted policy can be disabled to force encrypted media")
    func localUnencryptedPolicyCanBeDisabled() {
        let host = MirageHostService(
            networkConfiguration: MirageNetworkConfiguration(
                requireEncryptedMediaOnLocalNetwork: true
            )
        )

        #expect(host.mediaEncryptionEnabledForAcceptedSession(isPeerToPeer: true))
        #expect(host.mediaEncryptionEnabledForAcceptedSession(isPeerToPeer: false))
    }
}
#endif
