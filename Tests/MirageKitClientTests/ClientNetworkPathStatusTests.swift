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

    @Test("Bridge interfaces surface as Thunderbolt Bridge")
    func thunderboltBridgeDisplayName() {
        let status = makeStatus(kind: .wired, interfaceNames: ["bridge0"], usesWired: true)

        #expect(status.displayName == "Thunderbolt Bridge")
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
