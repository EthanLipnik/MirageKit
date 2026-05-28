//
//  MirageEffectiveMediaPathPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/27/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Mirage Effective Media Path Policy")
struct MirageEffectiveMediaPathPolicyTests {
    @Test("Client WiFi profile wins over host wired snapshot")
    func clientWiFiProfileWinsOverHostWiredSnapshot() {
        let policy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wired),
            clientPathKind: .wifi,
            clientMediaPathProfile: .localWiFi,
            clientPathSignature: "client-wifi"
        )

        #expect(policy.hostPathKind == .wired)
        #expect(policy.clientPathKind == .wifi)
        #expect(policy.transportPathKind == .wifi)
        #expect(policy.mediaPathProfile == .localWiFi)
    }

    @Test("Either side AWDL resolves AWDL radio policy")
    func eitherSideAwdlResolvesAwdlRadioPolicy() {
        let hostAwdl = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .awdl),
            clientPathKind: .wifi,
            clientMediaPathProfile: .localWiFi,
            clientPathSignature: "client-wifi"
        )
        #expect(hostAwdl.transportPathKind == .awdl)
        #expect(hostAwdl.mediaPathProfile == .awdlRadio)

        let clientAwdl = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wired),
            clientPathKind: .awdl,
            clientMediaPathProfile: .awdlRadio,
            clientPathSignature: "client-awdl"
        )
        #expect(clientAwdl.transportPathKind == .awdl)
        #expect(clientAwdl.mediaPathProfile == .awdlRadio)
    }

    @Test("Nil or unknown client profile falls back to host")
    func nilOrUnknownClientProfileFallsBackToHost() {
        let nilClient = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wired),
            clientPathKind: nil,
            clientMediaPathProfile: nil,
            clientPathSignature: nil
        )
        #expect(nilClient.transportPathKind == .wired)
        #expect(nilClient.mediaPathProfile == .wired)

        let unknownClient = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wifi),
            clientPathKind: .unknown,
            clientMediaPathProfile: .unknown,
            clientPathSignature: nil
        )
        #expect(unknownClient.transportPathKind == .wifi)
        #expect(unknownClient.mediaPathProfile == .localWiFi)
    }

    private static func snapshot(kind: MirageNetworkPathKind) -> MirageNetworkPathSnapshot {
        switch kind {
        case .awdl:
            MirageNetworkPathClassifier.classify(
                interfaceNames: ["awdl0"],
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
        case .wifi:
            MirageNetworkPathClassifier.classify(
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
        case .wired:
            MirageNetworkPathClassifier.classify(
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
                supportsIPv6: true
            )
        case .cellular, .vpn, .loopback, .other, .unknown:
            MirageNetworkPathClassifier.classify(
                interfaceNames: [],
                usesWiFi: false,
                usesWired: false,
                usesCellular: kind == .cellular,
                usesLoopback: kind == .loopback,
                usesOther: kind == .other,
                status: "satisfied",
                isExpensive: false,
                isConstrained: false,
                supportsIPv4: true,
                supportsIPv6: true
            )
        }
    }
}
#endif
