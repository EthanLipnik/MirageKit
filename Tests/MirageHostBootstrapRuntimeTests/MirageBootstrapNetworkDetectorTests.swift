//
//  MirageBootstrapNetworkDetectorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//

import MirageHostBootstrapRuntime
import Testing

@Suite("Bootstrap Network Detector")
struct MirageBootstrapNetworkDetectorTests {
    @Test("Virtual NICs are filtered when selecting Wake MAC")
    func virtualNICsAreFiltered() {
        let snapshot = MirageBootstrapNetworkDetector.snapshot(
            hardwareInterfaces: [
                interface(name: "en0", mac: "de:6e:68:e4:c7:37", kind: .ethernet),
                interface(name: "en1", mac: "c8:a3:62:16:05:06", kind: .ethernet),
            ],
            ifconfigText: """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether de:6e:68:e4:c7:37
            \tinet 192.168.139.3 netmask 0xfffffe00 broadcast 192.168.139.255
            \tstatus: active
            en1: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether c8:a3:62:16:05:06
            \tinet 192.168.1.10 netmask 0xffffff00 broadcast 192.168.1.255
            \tstatus: active
            """,
            defaultPort: 22
        )

        #expect(snapshot.wakeOnLANMACAddress == "c8:a3:62:16:05:06")
        #expect(snapshot.wakeOnLANBroadcasts == ["192.168.1.255"])
    }

    @Test("Ethernet is preferred over Wi-Fi")
    func ethernetPreferredOverWiFi() {
        let snapshot = MirageBootstrapNetworkDetector.snapshot(
            hardwareInterfaces: [
                interface(name: "en0", mac: "60:3e:5f:34:6a:3f", kind: .wifi),
                interface(name: "en5", mac: "c8:a3:62:16:05:06", kind: .ethernet),
            ],
            ifconfigText: """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether 60:3e:5f:34:6a:3f
            \tinet 192.168.1.12 netmask 0xffffff00 broadcast 192.168.1.255
            \tstatus: active
            en5: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether c8:a3:62:16:05:06
            \tinet 192.168.1.10 netmask 0xffffff00 broadcast 192.168.1.255
            \tstatus: active
            """,
            defaultPort: 22
        )

        #expect(snapshot.wakeOnLANMACAddress == "c8:a3:62:16:05:06")
        #expect(snapshot.isWakeInterfaceWiFi == false)
    }

    @Test("Inactive interfaces are rejected")
    func inactiveInterfacesRejected() {
        let snapshot = MirageBootstrapNetworkDetector.snapshot(
            hardwareInterfaces: [
                interface(name: "en0", mac: "c8:a3:62:16:05:06", kind: .ethernet),
                interface(name: "en1", mac: "60:3e:5f:34:6a:3f", kind: .wifi),
            ],
            ifconfigText: """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether c8:a3:62:16:05:06
            \tinet 192.168.1.10 netmask 0xffffff00 broadcast 192.168.1.255
            \tstatus: inactive
            en1: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether 60:3e:5f:34:6a:3f
            \tinet 192.168.1.12 netmask 0xffffff00 broadcast 192.168.1.255
            \tstatus: active
            """,
            defaultPort: 22
        )

        #expect(snapshot.wakeOnLANMACAddress == "60:3e:5f:34:6a:3f")
        #expect(snapshot.isWakeInterfaceWiFi)
    }

    @Test("Wi-Fi private address warning is reported")
    func wifiPrivateAddressWarning() {
        let snapshot = MirageBootstrapNetworkDetector.snapshot(
            hardwareInterfaces: [
                interface(name: "en0", mac: "60:3e:5f:34:6a:3f", kind: .wifi),
            ],
            ifconfigText: """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether ea:7f:a9:7f:a3:0a
            \tinet 192.168.1.12 netmask 0xffffff00 broadcast 192.168.1.255
            \tstatus: active
            """,
            defaultPort: 22
        )

        #expect(snapshot.wakeOnLANMACAddress == "ea:7f:a9:7f:a3:0a")
        #expect(snapshot.isWakeInterfaceWiFi)
        #expect(snapshot.hasWiFiPrivateAddressWarning)
    }

    @Test("Broadcasts and endpoints are deduped")
    func broadcastsAndEndpointsDeduped() {
        let snapshot = MirageBootstrapNetworkDetector.snapshot(
            hardwareInterfaces: [
                interface(name: "en0", mac: "c8:a3:62:16:05:06", kind: .ethernet),
            ],
            ifconfigText: """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether c8:a3:62:16:05:06
            \tinet 192.168.1.10 netmask 0xffffff00 broadcast 192.168.1.255
            \tinet 192.168.1.10 netmask 0xffffff00 broadcast 192.168.1.255
            \tstatus: active
            """,
            defaultPort: 22
        )

        #expect(snapshot.endpoints.count == 1)
        #expect(snapshot.wakeOnLANBroadcasts == ["192.168.1.255"])
    }

    private func interface(
        name: String,
        mac: String,
        kind: MirageBootstrapNetworkInterface.Kind
    ) -> MirageBootstrapNetworkInterface {
        MirageBootstrapNetworkInterface(
            name: name,
            displayName: name,
            kind: kind,
            hardwareMACAddress: mac
        )
    }
}
