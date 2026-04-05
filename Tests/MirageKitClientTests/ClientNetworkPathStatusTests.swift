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
    @Test("AWDL paths preserve the AWDL label")
    func awdlDisplayName() {
        let status = makeStatus(kind: .awdl, interfaceNames: ["awdl0"], usesOther: true)

        #expect(status.displayName == "AWDL")
    }

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

    @Test("Bridge interfaces surface as Thunderbolt Bridge")
    func thunderboltBridgeDisplayName() {
        let status = makeStatus(kind: .wired, interfaceNames: ["bridge0"], usesWired: true)

        #expect(status.displayName == "Thunderbolt Bridge")
    }

    @Test("Generic wired paths do not assume Ethernet")
    func wiredDisplayName() {
        let status = makeStatus(kind: .wired, interfaceNames: ["en7"], usesWired: true)

        #expect(status.displayName == "Wired")
    }

    @Test("Tunnel interfaces surface as overlay paths")
    func overlayDisplayName() {
        let status = makeStatus(kind: .other, interfaceNames: ["utun4"], usesOther: true)

        #expect(status.displayName == "VPN / Overlay")
    }

    @Test("Interface type summary combines active flags")
    func interfaceTypeSummary() {
        let status = MirageClientNetworkPathStatus(
            kind: .other,
            status: "satisfied",
            interfaceNames: ["en7", "utun4"],
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            usesWiFi: false,
            usesWired: true,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true
        )

        #expect(status.interfaceTypeSummary == "Wired + Other")
    }

    @Test("Generic wired paths explain that classification is broad")
    func wiredDiagnosticNote() {
        let status = makeStatus(kind: .wired, interfaceNames: ["en7"], usesWired: true)

        #expect(status.transportDiagnosticNote?.contains("generic wired path") == true)
    }

    @Test("Snapshot endpoint descriptions carry through to public status")
    func endpointDescriptionsCarryThrough() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["en7"],
            usesWiFi: false,
            usesWired: true,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            localEndpointDescription: "192.168.1.10:54321",
            remoteEndpointDescription: "192.168.1.20:51024"
        )

        let status = MirageClientNetworkPathStatus(snapshot: snapshot)

        #expect(status.localEndpointDescription == "192.168.1.10:54321")
        #expect(status.remoteEndpointDescription == "192.168.1.20:51024")
    }

    @Test("Protocol summary reflects the available IP families")
    func protocolSummaryVariants() {
        #expect(makeStatus(supportsIPv4: true, supportsIPv6: true).protocolSummary == "IPv4 + IPv6")
        #expect(makeStatus(supportsIPv4: true, supportsIPv6: false).protocolSummary == "IPv4")
        #expect(makeStatus(supportsIPv4: false, supportsIPv6: true).protocolSummary == "IPv6")
        #expect(makeStatus(supportsIPv4: false, supportsIPv6: false).protocolSummary == "none")
    }

    private func makeStatus(
        kind: MirageNetworkPathKind = .wifi,
        interfaceNames: [String] = ["en0"],
        supportsIPv4: Bool = true,
        supportsIPv6: Bool = true,
        usesWired: Bool = false,
        usesOther: Bool = false
    ) -> MirageClientNetworkPathStatus {
        MirageClientNetworkPathStatus(
            kind: kind,
            status: "satisfied",
            interfaceNames: interfaceNames,
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: supportsIPv4,
            supportsIPv6: supportsIPv6,
            usesWiFi: kind == .wifi,
            usesWired: usesWired,
            usesCellular: kind == .cellular,
            usesLoopback: kind == .loopback,
            usesOther: usesOther
        )
    }
}
