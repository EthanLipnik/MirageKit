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
    @Test("Wi-Fi path flags win over available AWDL interface names")
    func wifiPathFlagsWinOverAvailableAwdlInterfaceNames() {
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

        #expect(snapshot.kind == .wifi)
        #expect(snapshot.mediaProfile == .localWiFi)
        let status = MirageClientNetworkPathStatus(snapshot: snapshot)
        #expect(status.displayName == "Wi-Fi")
        #expect(!status.usesFixedRealtimeDisplayPolicy)
        #expect(!status.usesProximityWiredLikePolicy)
    }

    @Test("Scoped AWDL endpoint wins over Wi-Fi path flags")
    func scopedAwdlEndpointWinsOverWiFiPathFlags() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["en0", "awdl0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            localEndpointDescription: "[fe80::1%awdl0]:49152",
            remoteEndpointDescription: "[fe80::2%25awdl0]:49153"
        )

        #expect(snapshot.kind == .awdl)
        #expect(snapshot.mediaProfile == .awdlRadio)
        #expect(snapshot.signature.localizedStandardContains("kind=awdl"))
        let status = MirageClientNetworkPathStatus(snapshot: snapshot)
        #expect(status.usesFixedRealtimeDisplayPolicy)
        #expect(status.usesAwdlRadioInterface)
    }

    @Test("Selected Wi-Fi path wins over passive tunnel interface names")
    func selectedWiFiPathWinsOverPassiveTunnelInterfaceNames() {
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

        #expect(snapshot.kind == .wifi)
        #expect(snapshot.mediaProfile == .localWiFi)
        #expect(MirageClientNetworkPathStatus(snapshot: snapshot).displayName == "Wi-Fi")
    }

    @Test("Tunnel-only paths use VPN presentation")
    func tunnelOnlyPathsUseVPNPresentation() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["utun4"],
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

        #expect(snapshot.kind == .vpn)
        #expect(snapshot.mediaProfile == .vpnOrOverlay)
        #expect(MirageClientNetworkPathStatus(snapshot: snapshot).displayName == "VPN / Overlay")
    }

    @Test("Active tunnel path wins over Wi-Fi flags")
    func activeTunnelPathWinsOverWiFiFlags() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["utun4"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            localEndpointDescription: "100.89.180.101:53023",
            remoteEndpointDescription: "100.75.233.52:55395"
        )

        #expect(snapshot.kind == .vpn)
        #expect(snapshot.mediaProfile == .vpnOrOverlay)
        #expect(snapshot.signature.localizedStandardContains("kind=vpn"))
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
        #expect(snapshot.mediaProfile == .proximityWiredLike)
        #expect(!status.usesFixedRealtimeDisplayPolicy)
        #expect(status.usesProximityWiredLikePolicy)
        #expect(status.usesUSBProximityInterface)
        #expect(!status.usesAwdlRadioInterface)
        #expect(status.displayName == "USB-C Proximity")
        #expect(status.transportDiagnosticNote?.contains("USB-C proximity") == true)
    }

    @Test("Apple private proximity interface wins media policy when AWDL is also present")
    func applePrivateProximityClassifierWinsMediaPolicyWhenAwdlIsAlsoPresent() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["awdl0", "anpi0"],
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
        #expect(snapshot.mediaProfile == .proximityWiredLike)
        #expect(!status.usesFixedRealtimeDisplayPolicy)
        #expect(status.usesProximityWiredLikePolicy)
        #expect(status.usesUSBProximityInterface)
        #expect(status.usesAwdlRadioInterface)
        #expect(status.displayName == "USB-C Proximity")
    }

    @Test("Bridge interface wins media policy when AWDL is also present")
    func bridgeClassifierWinsMediaPolicyWhenAwdlIsAlsoPresent() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["awdl0", "bridge100"],
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
        #expect(snapshot.mediaProfile == .wired)
        #expect(!status.usesFixedRealtimeDisplayPolicy)
        #expect(!status.usesProximityWiredLikePolicy)
        #expect(status.usesWiredBridgeInterface)
        #expect(status.usesAwdlRadioInterface)
        #expect(status.displayName == "Thunderbolt Bridge")
    }

    @Test("Low-latency wireless interfaces use local Wi-Fi media policy")
    func lowLatencyWirelessClassifierUsesLocalWiFiMediaPolicy() {
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
        #expect(snapshot.mediaProfile == .localWiFi)
        #expect(!status.usesFixedRealtimeDisplayPolicy)
        #expect(!status.usesProximityWiredLikePolicy)
        #expect(!status.usesAwdlRadioInterface)
        #expect(status.usesLowLatencyWirelessInterface)
        #expect(status.displayName == "Low-Latency Wireless")
    }

    @Test("AWDL path kind with only LLW resolves local Wi-Fi media policy")
    func awdlPathKindWithOnlyLowLatencyWirelessResolvesLocalWiFiMediaPolicy() {
        let profile = MirageMediaPathProfile.classify(
            pathKind: .awdl,
            interfaceNames: ["llw0"],
            usesWiFi: true
        )
        let resolved = MirageMediaPathProfile.resolveRealtimeProfile(
            pathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            interfaceNames: ["llw0"]
        )

        #expect(profile == .localWiFi)
        #expect(resolved == .localWiFi)
    }

    @Test("Wi-Fi baseline uses local Wi-Fi media policy")
    func wifiBaselineUsesLocalWiFiMediaPolicy() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["en0"],
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

        #expect(snapshot.kind == .wifi)
        #expect(snapshot.mediaProfile == .localWiFi)
        #expect(!status.usesFixedRealtimeDisplayPolicy)
        #expect(!status.usesProximityWiredLikePolicy)
        #expect(status.displayName == "Wi-Fi")
    }

    @Test("Bridge-only baseline uses wired media policy")
    func bridgeOnlyBaselineUsesWiredMediaPolicy() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["bridge100"],
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

        #expect(snapshot.kind == .wired)
        #expect(snapshot.mediaProfile == .wired)
        #expect(!status.usesFixedRealtimeDisplayPolicy)
        #expect(!status.usesProximityWiredLikePolicy)
        #expect(status.usesWiredBridgeInterface)
        #expect(status.displayName == "Thunderbolt Bridge")
    }

    @Test("Legacy AWDL path kind defaults to radio media policy")
    func legacyAwdlPathKindDefaultsToRadioMediaPolicy() {
        let profile = MirageMediaPathProfile.classify(
            pathKind: .awdl,
            interfaceNames: []
        )

        #expect(profile == .awdlRadio)
    }

    @Test("Scoped AWDL path kind wins over passive wired flags")
    func scopedAwdlPathKindWinsOverPassiveWiredFlags() {
        let profile = MirageMediaPathProfile.classify(
            pathKind: .awdl,
            interfaceNames: ["awdl0", "en3"],
            usesWired: true,
            usesLoopback: true
        )
        let resolved = MirageMediaPathProfile.resolveRealtimeProfile(
            pathKind: .awdl,
            mediaPathProfile: .wired,
            interfaceNames: ["awdl0", "en3"]
        )

        #expect(profile == .awdlRadio)
        #expect(resolved == .awdlRadio)
    }

    @Test("Wi-Fi media profile wins over available AWDL interface name")
    func wifiMediaProfileWinsOverAvailableAwdlInterfaceName() {
        let profile = MirageMediaPathProfile.classify(
            pathKind: .wifi,
            interfaceNames: ["en0", "awdl0"],
            usesWiFi: true
        )

        #expect(profile == .localWiFi)
    }

    @Test("Tunnel-only media profile wins over leaked Wi-Fi flags")
    func tunnelOnlyMediaProfileWinsOverLeakedWiFiFlags() {
        let profile = MirageMediaPathProfile.classify(
            pathKind: .wifi,
            interfaceNames: ["utun4"],
            usesWiFi: true,
            usesOther: true
        )

        #expect(profile == .vpnOrOverlay)
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

    @Test("Local default route uses VPN when tunnel is the only active interface")
    func localDefaultRouteUsesVPNWhenTunnelIsTheOnlyActiveInterface() {
        let kind = MirageNetworkPathClassifier.classifyLocalDefaultRouteKind(
            interfaceNames: ["utun4"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true
        )

        #expect(kind == .vpn)
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

    @Test("Local default route recognizes low-latency wireless as peer path")
    func localDefaultRouteRecognizesLowLatencyWirelessAsPeerPath() {
        let kind = MirageNetworkPathClassifier.classifyLocalDefaultRouteKind(
            interfaceNames: ["llw0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false
        )

        #expect(kind == .awdl)
    }

    @Test("Local default route treats USB-C proximity as wired-like")
    func localDefaultRouteTreatsUSBCProximityAsWiredLike() {
        let kind = MirageNetworkPathClassifier.classifyLocalDefaultRouteKind(
            interfaceNames: ["anpi0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true
        )

        #expect(kind == .wired)
    }

    @Test("Local default route treats USB-C plus AWDL as wired-like")
    func localDefaultRouteTreatsUSBCPlusAwdlAsWiredLike() {
        let kind = MirageNetworkPathClassifier.classifyLocalDefaultRouteKind(
            interfaceNames: ["awdl0", "anpi0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true
        )

        #expect(kind == .wired)
    }
}
