//
//  MirageHostBootstrapConfigurationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//
//  Coverage for bootstrap configuration defaults and Loom metadata projection.
//

import Loom
import MirageHostBootstrapRuntime
import Testing

@Suite("Bootstrap Configuration")
struct MirageHostBootstrapConfigurationTests {
    @Test("Defaults start disabled with bootstrap-safe ports")
    func defaults() {
        let configuration = MirageHostBootstrapConfiguration()

        #expect(configuration.enabled == false)
        #expect(configuration.userEndpointHost.isEmpty)
        #expect(configuration.userEndpointPort == 22)
        #expect(configuration.sshPort == 22)
        #expect(configuration.controlPort == 9851)
        #expect(configuration.autoEndpoints.isEmpty)
        #expect(configuration.controlAuthSecret.isEmpty == false)
        #expect(configuration.remoteLoginReachable == false)
        #expect(configuration.preloginDaemonReady == false)
    }

    @Test("JSON round-trip preserves configured values")
    func jsonRoundTrip() throws {
        let original = MirageHostBootstrapConfiguration(
            enabled: true,
            userEndpointHost: "host.local",
            userEndpointPort: 2200,
            sshPort: 2222,
            controlPort: 9852,
            sshHostKeyFingerprint: "SHA256:test",
            controlAuthSecret: "control-secret",
            autoEndpoints: [
                LoomBootstrapEndpoint(host: "10.0.0.2", port: 22, source: .auto),
            ],
            wakeOnLANMACAddress: "AA:BB:CC:DD:EE:FF",
            wakeOnLANBroadcasts: ["192.168.1.255"],
            remoteLoginReachable: true,
            preloginDaemonReady: true
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MirageHostBootstrapConfiguration.self, from: encoded)

        #expect(decoded == original)
    }

    @Test("Bootstrap metadata conversion trims values and prioritizes user endpoint")
    func metadataConversion() {
        let configuration = MirageHostBootstrapConfiguration(
            enabled: true,
            userEndpointHost: " host.local ",
            userEndpointPort: 2200,
            sshPort: 2222,
            controlPort: 9852,
            sshHostKeyFingerprint: " SHA256:test ",
            controlAuthSecret: " control-secret ",
            autoEndpoints: [
                LoomBootstrapEndpoint(host: "10.0.0.2", port: 22, source: .auto),
            ],
            wakeOnLANMACAddress: " AA:BB:CC:DD:EE:FF ",
            wakeOnLANBroadcasts: [" 192.168.1.255 ", " "],
            remoteLoginReachable: true,
            preloginDaemonReady: true
        )

        let metadata = configuration.toBootstrapMetadata()

        #expect(metadata?.version == 2)
        #expect(metadata?.enabled == true)
        #expect(metadata?.sshPort == 2222)
        #expect(metadata?.controlPort == 9852)
        #expect(metadata?.sshHostKeyFingerprint == "SHA256:test")
        #expect(metadata?.controlAuthSecret == "control-secret")
        #expect(metadata?.endpoints.count == 2)
        #expect(metadata?.endpoints.first?.host == "host.local")
        #expect(metadata?.endpoints.first?.port == 2200)
        #expect(metadata?.endpoints.first?.source == .user)
        #expect(metadata?.wakeOnLAN?.macAddress == "AA:BB:CC:DD:EE:FF")
        #expect(metadata?.wakeOnLAN?.broadcastAddresses == ["192.168.1.255"])
    }
}
