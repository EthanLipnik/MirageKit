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
    @Test("JSON round-trip preserves configured values")
    func jsonRoundTrip() throws {
        let original = MirageHostBootstrapConfiguration(
            enabled: true,
            userEndpointHost: "host.local",
            userEndpointPort: 2200,
            sshPort: 2222,
            controlPort: 9852,
            controlAuthSecret: "control-secret",
            autoEndpoints: [
                LoomBootstrapEndpoint(host: "10.0.0.2", port: 22, source: .auto),
            ],
            sshHostKeyFingerprints: ["SHA256:test-fingerprint"],
            manualWakeOnLANMACAddress: "11:22:33:44:55:66",
            wakeOnLANMACAddress: "AA:BB:CC:DD:EE:FF",
            wakeOnLANBroadcasts: ["192.168.1.255"],
            wakeOnLANInterfaceName: "en0",
            wakeOnLANInterfaceDisplayName: "Ethernet",
            wakeOnLANUsesWiFi: false,
            wakeOnLANWiFiPrivateAddressWarning: false,
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
            controlAuthSecret: " control-secret ",
            autoEndpoints: [
                LoomBootstrapEndpoint(host: "10.0.0.2", port: 22, source: .auto),
            ],
            sshHostKeyFingerprints: [" SHA256:test-fingerprint ", " "],
            manualWakeOnLANMACAddress: " 11:22:33:44:55:66 ",
            wakeOnLANMACAddress: " AA:BB:CC:DD:EE:FF ",
            wakeOnLANBroadcasts: [" 192.168.1.255 ", " "],
            remoteLoginReachable: true,
            preloginDaemonReady: true
        )

        let metadata = configuration.toBootstrapMetadata()

        #expect(metadata?.version == LoomBootstrapMetadata.currentVersion)
        #expect(metadata?.enabled == true)
        #expect(metadata?.supportsPreloginDaemon == true)
        #expect(metadata?.sshPort == 2222)
        #expect(metadata?.controlPort == 9852)
        #expect(metadata?.endpoints.count == 2)
        #expect(metadata?.endpoints.first?.host == "host.local")
        #expect(metadata?.endpoints.first?.port == 2200)
        #expect(metadata?.endpoints.first?.source == .user)
        #expect(metadata?.sshHostKeyFingerprints == ["SHA256:test-fingerprint"])
        #expect(metadata?.wakeOnLAN?.macAddress == "11:22:33:44:55:66")
        #expect(metadata?.wakeOnLAN?.broadcastAddresses == ["192.168.1.255"])
    }

    @Test("Invalid manual Wake MAC falls back to auto-detected MAC")
    func invalidManualWakeMACFallback() {
        let configuration = MirageHostBootstrapConfiguration(
            enabled: true,
            manualWakeOnLANMACAddress: "invalid",
            wakeOnLANMACAddress: "AA:BB:CC:DD:EE:FF",
            wakeOnLANBroadcasts: ["192.168.1.255"]
        )

        #expect(configuration.toBootstrapMetadata()?.wakeOnLAN?.macAddress == "AA:BB:CC:DD:EE:FF")
    }
}
