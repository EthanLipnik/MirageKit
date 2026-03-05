//
//  MediaTransportCandidateOrderingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

@testable import MirageKitClient
@testable import MirageKit
import Network
import Testing

#if os(macOS)
@Suite("Media Transport Candidate Ordering")
struct MediaTransportCandidateOrderingTests {
    @Test("Wired link-local control endpoint prefers remote endpoint before Bonjour fallback")
    func wiredLinkLocalPrefersRemoteEndpoint() {
        let candidates = MirageClientService.orderedMediaTransportCandidates(
            preferredHost: nil,
            preferredIncludePeerToPeer: nil,
            serviceHost: NWEndpoint.Host("Altair"),
            remoteHost: NWEndpoint.Host("fe80::1%en12"),
            endpointHost: nil,
            configuredPeerToPeer: true,
            controlPathKind: .wired
        )

        #expect(candidates.count >= 2)
        #expect(candidates[0].label == "control-remote-endpoint")
        #expect(candidates[1].label == "bonjour-hostname-no-p2p")
    }

    @Test("Wi-Fi link-local keeps Bonjour no-p2p fallback ahead of remote endpoint")
    func wifiLinkLocalKeepsBonjourFallbackAhead() {
        let candidates = MirageClientService.orderedMediaTransportCandidates(
            preferredHost: nil,
            preferredIncludePeerToPeer: nil,
            serviceHost: NWEndpoint.Host("Altair"),
            remoteHost: NWEndpoint.Host("fe80::1%en0"),
            endpointHost: nil,
            configuredPeerToPeer: true,
            controlPathKind: .wifi
        )

        #expect(candidates.count >= 2)
        #expect(candidates[0].label == "bonjour-hostname-no-p2p")
        #expect(candidates[1].label == "control-remote-endpoint")
    }
}
#endif
