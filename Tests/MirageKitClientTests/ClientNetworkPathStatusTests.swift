//
//  ClientNetworkPathStatusTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//
//  Public network-path presentation helpers for stream status UI.
//

@testable import MirageKitClient
import MirageKit
import Testing

@Suite("Client Network Path Status")
struct ClientNetworkPathStatusTests {
    @Test("AWDL interface names win over Wi-Fi path flags")
    func awdlClassifierWinsOverWiFiFlags() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["en0", "awdl0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(snapshot.kind == .awdl)
        #expect(MirageClientNetworkPathStatus(snapshot: snapshot).displayName == "AWDL")
    }

    @Test("Tunnel interface names win over Wi-Fi path flags")
    func overlayClassifierWinsOverWiFiFlags() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["en0", "utun4"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(snapshot.kind == .vpn)
        #expect(MirageClientNetworkPathStatus(snapshot: snapshot).displayName == "VPN / Overlay")
    }

    @Test("Apple private proximity interfaces use proximity-class path presentation")
    func applePrivateProximityClassifierUsesProximityPresentation() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["anpi0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
        let status = MirageClientNetworkPathStatus(snapshot: snapshot)

        #expect(snapshot.kind == .awdl)
        #expect(status.displayName == "USB-C Proximity")
        #expect(status.transportDiagnosticNote?.contains("USB-C proximity") == true)
    }

    @Test("Low-latency wireless interfaces use proximity-class path presentation")
    func lowLatencyWirelessClassifierUsesProximityPresentation() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["llw0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
        let status = MirageClientNetworkPathStatus(snapshot: snapshot)

        #expect(snapshot.kind == .awdl)
        #expect(status.displayName == "Low-Latency Wireless")
    }

    @Test("Local default route keeps Wi-Fi ahead of available tunnel interfaces")
    func localDefaultRouteKeepsWiFiAheadOfAvailableTunnelInterfaces() {
        let kind = MirageNetworkPathClassifier.classifyLocalDefaultRouteKind(
            interfaceNames: ["en0", "utun4"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true
        )

        #expect(kind == .wifi)
    }

    @Test("Local default route keeps wired ahead of available tunnel interfaces")
    func localDefaultRouteKeepsWiredAheadOfAvailableTunnelInterfaces() {
        let kind = MirageNetworkPathClassifier.classifyLocalDefaultRouteKind(
            interfaceNames: ["en7", "utun4"],
            usesWiFi: false,
            usesWired: true,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true
        )

        #expect(kind == .wired)
    }

    @Test("Local default route still recognizes AWDL when it is the only peer path")
    func localDefaultRouteRecognizesAwdlWhenItIsTheOnlyPeerPath() {
        let kind = MirageNetworkPathClassifier.classifyLocalDefaultRouteKind(
            interfaceNames: ["awdl0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true
        )

        #expect(kind == .awdl)
    }
}
