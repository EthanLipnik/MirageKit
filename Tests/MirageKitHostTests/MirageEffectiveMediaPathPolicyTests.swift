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
import Loom
import MirageConnectivity
import MirageCore
import MirageMedia

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

    @Test("VPN policy overrides raw WiFi path observation")
    func vpnPolicyOverridesRawWiFiPathObservation() {
        let policy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wifi),
            clientPathKind: .wifi,
            clientMediaPathProfile: .localWiFi,
            clientPathSignature: "status=satisfied|kind=wifi|media=localWiFi|if=en0",
            clientPolicyPathKind: .vpn,
            clientPolicyMediaPathProfile: .vpnOrOverlay
        )

        #expect(policy.clientPathKind == .wifi)
        #expect(policy.clientMediaPathProfile == .localWiFi)
        #expect(policy.clientPolicyPathKind == .vpn)
        #expect(policy.clientPolicyMediaPathProfile == .vpnOrOverlay)
        #expect(policy.transportPathKind == .vpn)
        #expect(policy.mediaPathProfile == .vpnOrOverlay)
    }

    @Test("Stored VPN policy survives local-looking retune snapshots")
    func storedVPNPolicySurvivesLocalLookingRetuneSnapshots() {
        let startupPolicy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wifi),
            clientPathKind: .wifi,
            clientMediaPathProfile: .localWiFi,
            clientPathSignature: "status=satisfied|kind=wifi|media=localWiFi|if=en0",
            clientPolicyPathKind: .vpn,
            clientPolicyMediaPathProfile: .vpnOrOverlay
        )
        let evidence = HostStreamMediaPathClientEvidence(policy: startupPolicy)
        let retunedPolicy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wired),
            clientPathKind: evidence.pathKind,
            clientMediaPathProfile: evidence.mediaPathProfile,
            clientPathSignature: evidence.pathSignature,
            clientPolicyPathKind: evidence.policyPathKind,
            clientPolicyMediaPathProfile: evidence.policyMediaPathProfile
        )

        #expect(retunedPolicy.transportPathKind == .vpn)
        #expect(retunedPolicy.mediaPathProfile == .vpnOrOverlay)
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

    @Test("Stored client AWDL evidence survives host WiFi or unknown retune snapshots")
    func storedClientAwdlEvidenceSurvivesHostRetuneSnapshots() {
        for hostSnapshot in [Self.snapshot(kind: .wifi), Self.snapshot(kind: .unknown)] {
            let policy = MirageEffectiveMediaPathPolicy.resolve(
                hostSnapshot: hostSnapshot,
                clientPathKind: .awdl,
                clientMediaPathProfile: .awdlRadio,
                clientPathSignature: "status=satisfied|kind=awdl|media=awdlRadio|if=awdl0"
            )

            #expect(policy.transportPathKind == .awdl)
            #expect(policy.mediaPathProfile == .awdlRadio)
        }
    }

    @Test("Stored client LLW evidence resolves local WiFi policy")
    func storedClientLlwEvidenceResolvesLocalWiFiPolicy() {
        let policy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wifi),
            clientPathKind: .awdl,
            clientMediaPathProfile: .awdlRadio,
            clientPathSignature: "status=satisfied|kind=awdl|media=awdlRadio|if=llw0"
        )

        #expect(policy.transportPathKind == .wifi)
        #expect(policy.mediaPathProfile == .localWiFi)
    }

    @Test("AWDL resolved media path selects proximity realtime display queue")
    func awdlResolvedMediaPathSelectsProximityRealtimeDisplayQueue() {
        #expect(
            LoomAuthenticatedSession.mirageMediaSendProfile(for: .awdlRadio) == .proximityRealtimeDisplay
        )
        #expect(
            LoomAuthenticatedSession.mirageMediaSendProfile(for: .localWiFi) == .interactiveMedia
        )
    }

    @Test("AWDL realtime display keeps send pacing on single-lane Loom transport")
    func awdlRealtimeDisplayKeepsSendPacingOnSingleLaneLoomTransport() {
        #expect(
            LoomAuthenticatedSession.mirageMediaSendProfile(
                for: .awdlRadio,
                transportReceiveSemantics: "independent-reliable-unreliable"
            ) == .proximityRealtimeDisplay
        )
        #expect(
            LoomAuthenticatedSession.mirageMediaSendProfile(
                for: .awdlRadio,
                transportReceiveSemantics: "single-lane"
            ) == .proximityRealtimeDisplaySingleLane
        )
        #expect(
            LoomAuthenticatedSession.mirageMediaSendProfile(
                for: .localWiFi,
                transportReceiveSemantics: "single-lane"
            ) == .interactiveMedia
        )
    }

    @Test("Low-latency wireless host snapshot resolves local WiFi policy")
    func lowLatencyWirelessHostSnapshotResolvesLocalWiFiPolicy() {
        let hostSnapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
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

        #expect(hostSnapshot.kind == .wifi)
        #expect(hostSnapshot.mediaProfile == .localWiFi)

        let policy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: hostSnapshot,
            clientPathKind: .wifi,
            clientMediaPathProfile: .localWiFi,
            clientPathSignature: "client-wifi"
        )

        #expect(policy.transportPathKind == .wifi)
        #expect(policy.mediaPathProfile == .localWiFi)
        #expect(LoomAuthenticatedSession.mirageMediaSendProfile(for: policy.mediaPathProfile) == .interactiveMedia)
    }

    @Test("AWDL proximity claim with LLW signature resolves local WiFi policy")
    func awdlProximityClaimWithLlwSignatureResolvesLocalWiFiPolicy() {
        let policy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wired),
            clientPathKind: .awdl,
            clientMediaPathProfile: .proximityWiredLike,
            clientPathSignature: "status=satisfied|kind=awdl|media=proximityWiredLike|if=llw0"
        )

        #expect(policy.transportPathKind == .wifi)
        #expect(policy.mediaPathProfile == .localWiFi)
    }

    @Test("AWDL proximity claim without NCM signature resolves radio policy")
    func awdlProximityClaimWithoutNcmSignatureResolvesRadioPolicy() {
        let policy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wired),
            clientPathKind: .awdl,
            clientMediaPathProfile: .proximityWiredLike,
            clientPathSignature: "status=satisfied|kind=awdl|media=proximityWiredLike|if=awdl0"
        )

        #expect(policy.transportPathKind == .awdl)
        #expect(policy.mediaPathProfile == .awdlRadio)
    }

    @Test("AWDL proximity claim with NCM signature preserves proximity policy")
    func awdlProximityClaimWithNcmSignaturePreservesProximityPolicy() {
        let policy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wired),
            clientPathKind: .awdl,
            clientMediaPathProfile: .proximityWiredLike,
            clientPathSignature: "status=satisfied|kind=awdl|media=proximityWiredLike|if=anpi0"
        )

        #expect(policy.transportPathKind == .wired)
        #expect(policy.mediaPathProfile == .proximityWiredLike)
    }

    @Test("Mixed WiFi and available AWDL host snapshot resolves WiFi media policy")
    func mixedWiFiAndAvailableAwdlHostSnapshotResolvesWiFiMediaPolicy() {
        let hostSnapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
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

        #expect(hostSnapshot.kind == .wifi)
        #expect(hostSnapshot.mediaProfile == .localWiFi)
    }

    @Test("APNI host route is not masked by client generic wired route")
    func apniHostRouteIsNotMaskedByClientGenericWiredRoute() {
        let hostSnapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
            interfaceNames: ["apni2"],
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
        #expect(hostSnapshot.kind == .wired)
        #expect(hostSnapshot.mediaProfile == .proximityWiredLike)

        let policy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: hostSnapshot,
            clientPathKind: .wired,
            clientMediaPathProfile: .wired,
            clientPathSignature: "client-en5"
        )

        #expect(policy.transportPathKind == .wired)
        #expect(policy.mediaPathProfile == .proximityWiredLike)
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

    private static func snapshot(kind: MirageCore.MirageNetworkPathKind) -> MirageConnectivity.MirageNetworkPathSnapshot {
        switch kind {
        case .awdl:
            MirageConnectivity.MirageNetworkPathClassifier.classify(
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
            MirageConnectivity.MirageNetworkPathClassifier.classify(
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
            MirageConnectivity.MirageNetworkPathClassifier.classify(
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
            MirageConnectivity.MirageNetworkPathClassifier.classify(
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
