//
//  MirageConnectivityHostMediaPathSnapshotTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageCore
@testable import MirageConnectivity
import MirageMedia
import Testing

@Suite("Mirage Connectivity Host Media Path Snapshot")
struct MirageConnectivityHostMediaPathSnapshotTests {
    @Test("Live Loom path snapshot wins over bootstrap path snapshot")
    func liveLoomPathSnapshotWinsOverBootstrapPathSnapshot() {
        let selected = currentHostMediaPathSnapshot(
            liveSnapshot: Self.loomSnapshot(kind: .awdl),
            bootstrapSnapshot: Self.loomSnapshot(kind: .wifi)
        )

        #expect(selected?.kind == .awdl)
        #expect(selected?.mediaProfile == .awdlRadio)
    }

    private static func loomSnapshot(kind: MirageCore.MirageNetworkPathKind) -> LoomSessionNetworkPathSnapshot {
        switch kind {
        case .awdl:
            LoomSessionNetworkPathSnapshot(
                status: .satisfied,
                interfaceNames: ["awdl0"],
                isExpensive: false,
                isConstrained: false,
                supportsIPv4: true,
                supportsIPv6: true,
                usesWiFi: false,
                usesWiredEthernet: false,
                usesCellular: false,
                usesLoopback: false,
                usesOther: true,
                localEndpoint: nil,
                remoteEndpoint: nil
            )
        case .wifi:
            LoomSessionNetworkPathSnapshot(
                status: .satisfied,
                interfaceNames: ["en0"],
                isExpensive: false,
                isConstrained: false,
                supportsIPv4: true,
                supportsIPv6: true,
                usesWiFi: true,
                usesWiredEthernet: false,
                usesCellular: false,
                usesLoopback: false,
                usesOther: false,
                localEndpoint: nil,
                remoteEndpoint: nil
            )
        case .wired:
            LoomSessionNetworkPathSnapshot(
                status: .satisfied,
                interfaceNames: ["en7"],
                isExpensive: false,
                isConstrained: false,
                supportsIPv4: true,
                supportsIPv6: true,
                usesWiFi: false,
                usesWiredEthernet: true,
                usesCellular: false,
                usesLoopback: false,
                usesOther: false,
                localEndpoint: nil,
                remoteEndpoint: nil
            )
        case .cellular, .vpn, .loopback, .other, .unknown:
            LoomSessionNetworkPathSnapshot(
                status: .satisfied,
                interfaceNames: [],
                isExpensive: false,
                isConstrained: false,
                supportsIPv4: true,
                supportsIPv6: true,
                usesWiFi: false,
                usesWiredEthernet: false,
                usesCellular: kind == .cellular,
                usesLoopback: kind == .loopback,
                usesOther: kind == .other,
                localEndpoint: nil,
                remoteEndpoint: nil
            )
        }
    }
}
