//
//  MirageEndpointClassifierTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/3/26.
//

import MirageKit
import Network
import Testing

@Suite("Mirage Endpoint Classifier")
struct MirageEndpointClassifierTests {
    @Test("Classifies Tailscale IPv4 CGNAT boundaries")
    func classifiesTailscaleIPv4CGNATBoundaries() {
        #expect(MirageEndpointClassifier.classifyHostname("100.64.0.1") == .tailscaleIPv4)
        #expect(MirageEndpointClassifier.classifyHostname("100.127.255.254") == .tailscaleIPv4)
        #expect(MirageEndpointClassifier.classifyHostname("100.63.255.254") == .unknown)
        #expect(MirageEndpointClassifier.classifyHostname("100.128.0.1") == .unknown)
    }

    @Test("Classifies Tailscale IPv6 prefix")
    func classifiesTailscaleIPv6Prefix() {
        #expect(MirageEndpointClassifier.classifyHostname("fd7a:115c:a1e0::1") == .tailscaleIPv6)
        #expect(MirageEndpointClassifier.classifyHostname("[fd7a:115c:a1e0::99]") == .tailscaleIPv6)
        #expect(MirageEndpointClassifier.classifyHostname("fd00::1") == .privateLAN)
    }

    @Test("Classifies MagicDNS and Bonjour names")
    func classifiesMagicDNSAndBonjourNames() {
        #expect(MirageEndpointClassifier.classifyHostname("altair.tail9a6b50.ts.net") == .tailscaleMagicDNS)
        #expect(MirageEndpointClassifier.classifyHostname("studio.ts.example.com") == .tailscaleMagicDNS)
        #expect(MirageEndpointClassifier.classifyHostname("Altair.local") == .bonjour)
        #expect(MirageEndpointClassifier.classifyHostname("Altair") == .bonjour)
    }

    @Test("Classifies LAN, public IPv6, and unknown names")
    func classifiesLANPublicIPv6AndUnknownNames() throws {
        let privateIPv4 = try #require(IPv4Address("192.168.50.24"))
        let publicIPv6 = try #require(IPv6Address("2607:f8b0:4005:805::200e"))

        #expect(MirageEndpointClassifier.classify(.ipv4(privateIPv4)) == .privateLAN)
        #expect(MirageEndpointClassifier.classify(.ipv6(publicIPv6)) == .publicIPv6)
        #expect(MirageEndpointClassifier.classifyHostname("example.com") == .unknown)
    }
}
