//
//  MirageConnectivityTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageCore
@testable import MirageConnectivity
import MirageDiagnostics
import MirageIdentity
import MirageMedia
import Network
import Testing
import MirageConnectivity
import MirageWire

@Suite("MirageConnectivity")
struct MirageConnectivityTests {
    @Test("Peer descriptors project Loom peers without exposing Loom types")
    func peerDescriptorsProjectLoomPeers() throws {
        let deviceID = try #require(UUID(uuidString: "50000000-0000-0000-0000-000000000001"))
        let advertisement = LoomPeerAdvertisement(
            protocolVersion: 260604,
            deviceID: deviceID,
            identityKeyID: "identity-key",
            deviceType: .mac,
            directTransports: [
                LoomDirectTransportAdvertisement(
                    transportKind: .udp,
                    port: MirageNetworkDefaults.directUDPPort,
                    pathKind: .awdl
                ),
            ]
        )
        let peer = LoomPeer(
            id: deviceID,
            appID: "com.example.MirageHost",
            name: "Studio",
            deviceType: .mac,
            endpoint: .hostPort(
                host: NWEndpoint.Host("studio.local"),
                port: try #require(NWEndpoint.Port(rawValue: MirageNetworkDefaults.directTCPPort))
            ),
            advertisement: advertisement
        )

        let descriptor = MirageConnectivityLoomAdapter.peerDescriptor(
            from: peer,
            targetSource: .bonjour
        )

        #expect(descriptor.id.deviceID == deviceID)
        #expect(descriptor.id.appID == "com.example.MirageHost")
        #expect(descriptor.name == "Studio")
        #expect(descriptor.deviceType == .mac)
        #expect(descriptor.protocolVersion == 260604)
        #expect(descriptor.identityKeyID == "identity-key")
        #expect(descriptor.targetSource == .bonjour)
        #expect(descriptor.directTransports == [
            MirageConnectivity.MirageDirectTransportDescriptor(
                kind: .udp,
                port: MirageNetworkDefaults.directUDPPort,
                pathKind: .proximityWireless
            ),
        ])

        let host = MirageConnectivity.MirageHostDescriptor(
            peer: descriptor,
            sessionAvailability: .credentialsAndUserIdentifierRequired,
            acceptsNewConnections: true,
            allowsRemoteAccess: false
        )
        let decoded = try JSONDecoder().decode(
            MirageConnectivity.MirageHostDescriptor.self,
            from: try JSONEncoder().encode(host)
        )
        #expect(decoded == host)
        #expect(decoded.sessionAvailability?.requiresCredentials == true)
        #expect(decoded.sessionAvailability?.requiresUserIdentifier == true)
    }

    @Test("Local identity snapshots project Loom account identities")
    func localIdentitySnapshotsProjectLoomAccountIdentities() {
        let publicKey = Data([0x04, 0x05, 0x06])
        let loomIdentity = LoomAccountIdentity(
            keyID: LoomIdentityManager.keyID(for: publicKey),
            publicKey: publicKey
        )

        let snapshot = MirageLocalIdentitySnapshot(loomIdentity: loomIdentity)

        #expect(snapshot.keyID == loomIdentity.keyID)
        #expect(snapshot.publicKey == publicKey)
        #expect(snapshot.hasPublicKey)
    }

    @Test("Diagnostics submission policy projects Loom events")
    func diagnosticsSubmissionPolicyProjectsLoomEvents() {
        let event = LoomDiagnosticsErrorEvent(
            date: Date(),
            category: "client",
            severity: .error,
            source: .logger,
            message: "Desktop stream start timed out after 30s",
            fileID: #fileID,
            line: #line,
            function: #function,
            metadata: LoomDiagnosticsErrorMetadata(
                typeName: "Timeout",
                domain: "Mirage",
                code: 30
            )
        )

        let classification = MirageDiagnostics.MirageDiagnosticsSubmissionPolicy.classification(for: event)

        #expect(classification.disposition == .capture)
        #expect(classification.issueKind == "desktop-startup-failure")
        #expect(classification.failureStage == "startup")
    }

    @Test("Host session availability maps Loom states")
    func hostSessionAvailabilityMapsLoomStates() {
        let cases: [(LoomSessionAvailability, MirageWire.MirageHostSessionAvailability)] = [
            (.ready, .ready),
            (.credentialsRequired, .credentialsRequired),
            (.credentialsAndUserIdentifierRequired, .credentialsAndUserIdentifierRequired),
            (.unavailable, .unavailable),
        ]

        for (loomState, mirageState) in cases {
            #expect(MirageWire.MirageHostSessionAvailability(loomAvailability: loomState) == mirageState)
            #expect(mirageState.loomAvailability == loomState)
        }
    }

    @Test("Authenticated peer identity projects Loom peer identities")
    func authenticatedPeerIdentityProjectsLoomPeerIdentities() throws {
        let deviceID = try #require(UUID(uuidString: "50000000-0000-0000-0000-000000000002"))
        let publicKey = Data([0x01, 0x02, 0x03])
        let peer = LoomPeerIdentity(
            deviceID: deviceID,
            name: "Studio iPad",
            deviceType: .iPad,
            iCloudUserID: "icloud-user",
            identityKeyID: "identity-key",
            identityPublicKey: publicKey,
            isIdentityAuthenticated: true,
            advertisementMetadata: ["mirage.client": "1"],
            endpoint: "192.0.2.10"
        )

        let identity = MirageAuthenticatedPeerIdentity(loomPeerIdentity: peer)

        #expect(identity.deviceID == deviceID)
        #expect(identity.displayName == "Studio iPad")
        #expect(identity.deviceType == .iPad)
        #expect(identity.iCloudUserID == "icloud-user")
        #expect(identity.identityKeyID == "identity-key")
        #expect(identity.identityPublicKey == publicKey)
        #expect(identity.isIdentityAuthenticated)
        #expect(identity.endpointDescription == "192.0.2.10")
    }

    @Test("Trust evaluation snapshots project Loom outcomes")
    func trustEvaluationSnapshotsProjectLoomOutcomes() {
        let cases: [(LoomTrustEvaluation, MirageTrustEvaluationSnapshot)] = [
            (
                LoomTrustEvaluation(
                    decision: .trusted,
                    shouldShowAutoTrustNotice: true
                ),
                MirageTrustEvaluationSnapshot(
                    decision: .trusted,
                    shouldShowAutoTrustNotice: true
                )
            ),
            (
                LoomTrustEvaluation(
                    decision: .requiresApproval,
                    shouldShowAutoTrustNotice: false
                ),
                MirageTrustEvaluationSnapshot(
                    decision: .requiresApproval,
                    shouldShowAutoTrustNotice: false
                )
            ),
            (
                LoomTrustEvaluation(
                    decision: .denied,
                    shouldShowAutoTrustNotice: true
                ),
                MirageTrustEvaluationSnapshot(
                    decision: .denied,
                    shouldShowAutoTrustNotice: true
                )
            ),
            (
                LoomTrustEvaluation(
                    decision: .unavailable("offline"),
                    shouldShowAutoTrustNotice: false
                ),
                MirageTrustEvaluationSnapshot(
                    decision: .unavailable,
                    shouldShowAutoTrustNotice: false,
                    unavailabilityReason: "offline"
                )
            ),
        ]

        for (loomEvaluation, expectedSnapshot) in cases {
            #expect(MirageTrustEvaluationSnapshot(loomTrustEvaluation: loomEvaluation) == expectedSnapshot)
        }
    }

    #if os(macOS)
    @MainActor
    @Test("Trust provider adapters bridge Mirage decisions into Loom handshakes")
    func trustProviderAdaptersBridgeMirageDecisionsIntoLoomHandshakes() async throws {
        let deviceID = try #require(UUID(uuidString: "50000000-0000-0000-0000-000000000003"))
        let publicKey = Data([0x04, 0x05, 0x06])
        let peer = LoomPeerIdentity(
            deviceID: deviceID,
            name: "Studio iPad",
            deviceType: .iPad,
            iCloudUserID: "icloud-user",
            identityKeyID: "identity-key",
            identityPublicKey: publicKey,
            isIdentityAuthenticated: true,
            endpoint: "192.0.2.20"
        )
        let provider = RecordingMirageTrustProvider(
            evaluation: MirageTrustEvaluationSnapshot(
                decision: .unavailable,
                shouldShowAutoTrustNotice: false,
                unavailabilityReason: "offline"
            )
        )
        let adapter = MirageTrustProviderLoomAdapter(provider: provider)

        let evaluation = await adapter.evaluateTrustOutcome(for: peer)
        try await adapter.grantTrust(to: peer)
        try await adapter.revokeTrust(for: deviceID)

        #expect(evaluation.decision == .unavailable("offline"))
        #expect(evaluation.shouldShowAutoTrustNotice == false)
        let evaluatedPeer = try #require(provider.evaluatedPeers.first)
        #expect(evaluatedPeer.deviceID == deviceID)
        #expect(evaluatedPeer.displayName == "Studio iPad")
        #expect(evaluatedPeer.iCloudUserID == "icloud-user")
        #expect(evaluatedPeer.identityKeyID == "identity-key")
        #expect(evaluatedPeer.identityPublicKey == publicKey)
        #expect(evaluatedPeer.isIdentityAuthenticated)
        #expect(evaluatedPeer.endpointDescription == "192.0.2.20")
        #expect(provider.grantedPeers.map(\.deviceID) == [deviceID])
        #expect(provider.revokedPeerIDs == [MiragePeerID(deviceID: deviceID)])
    }
    #endif

    @Test("Default network configuration uses core network defaults")
    func defaultNetworkConfigurationUsesCoreNetworkDefaults() {
        let configuration = MirageConnectivity.MirageNetworkConfiguration.default

        #expect(configuration.serviceType == MirageNetworkDefaults.serviceType)
        #expect(configuration.controlPort == MirageNetworkDefaults.directTCPPort)
        #expect(configuration.dataPort == MirageNetworkDefaults.directTCPPort)
        #expect(configuration.quicPort == MirageNetworkDefaults.directQUICPort)
        #expect(configuration.udpPort == MirageNetworkDefaults.directUDPPort)
        #expect(configuration.overlayProbePort == MirageNetworkDefaults.overlayProbePort)
        #expect(configuration.enabledDirectTransports == Set(MirageConnectivity.MirageTransportKind.allCases))
    }

    @Test("Network policies map to Loom configuration")
    func networkPoliciesMapToLoomConfiguration() {
        let policy = MirageConnectivity.MirageDirectConnectionPolicy(
            preferredLocalPathOrder: [.proximityWireless, .wired],
            preferredTransportOrder: [.quic, .tcp],
            localDiscoveryHostOverride: "127.0.0.1",
            racesLocalCandidates: false,
            racesRemoteCandidates: true
        )
        let configuration = MirageConnectivity.MirageNetworkConfiguration(
            serviceType: "_mirage-test._tcp",
            controlPort: 11,
            dataPort: 12,
            quicPort: 13,
            udpPort: 14,
            overlayProbePort: 15,
            maxPacketSize: 1_400,
            enableBonjour: false,
            enablePeerToPeer: false,
            requireEncryptedMediaOnLocalNetwork: true,
            enabledDirectTransports: [.quic, .tcp],
            directConnectionPolicy: policy,
            quicALPN: ["mirage-test"],
            datagramServiceClass: .responsiveData
        )

        let loomConfiguration = MirageConnectivityLoomAdapter.loomNetworkConfiguration(from: configuration)

        #expect(loomConfiguration.serviceType == "_mirage-test._tcp")
        #expect(loomConfiguration.controlPort == 11)
        #expect(loomConfiguration.dataPort == 12)
        #expect(loomConfiguration.quicPort == 13)
        #expect(loomConfiguration.udpPort == 14)
        #expect(loomConfiguration.overlayProbePort == 15)
        #expect(loomConfiguration.maxPacketSize == 1_400)
        #expect(!loomConfiguration.enableBonjour)
        #expect(!loomConfiguration.enablePeerToPeer)
        #expect(loomConfiguration.requireEncryptedMediaOnLocalNetwork)
        #expect(loomConfiguration.enabledDirectTransports == [.quic, .tcp])
        #expect(loomConfiguration.directConnectionPolicy.preferredLocalPathOrder == [.awdl, .wired])
        #expect(loomConfiguration.directConnectionPolicy.preferredTransportOrder == [.quic, .tcp])
        #expect(loomConfiguration.directConnectionPolicy.localDiscoveryHostOverride == "127.0.0.1")
        #expect(!loomConfiguration.directConnectionPolicy.racesLocalCandidates)
        #expect(loomConfiguration.directConnectionPolicy.racesRemoteCandidates)
        #expect(loomConfiguration.quicALPN == ["mirage-test"])
        #expect(loomConfiguration.directDatagramServiceClass == .responsiveData)
    }

    @Test("Client Loom network configuration resolves Mirage defaults")
    func clientLoomNetworkConfigurationResolvesMirageDefaults() {
        let defaultResolved = MirageConnectivityLoomAdapter.resolvedClientNetworkConfiguration(
            from: .default
        )

        #expect(defaultResolved.serviceType == MirageConnectivity.MirageNetworkConfiguration.default.serviceType)
        #expect(defaultResolved.quicALPN == MirageConnectivity.MirageNetworkConfiguration.default.quicALPN)

        var customConfiguration = LoomNetworkConfiguration.default
        customConfiguration.serviceType = "_custom-mirage._tcp"
        customConfiguration.quicALPN = ["legacy"]

        let customResolved = MirageConnectivityLoomAdapter.resolvedClientNetworkConfiguration(
            from: customConfiguration
        )

        #expect(customResolved.serviceType == "_custom-mirage._tcp")
        #expect(customResolved.quicALPN == MirageConnectivity.MirageNetworkConfiguration.default.quicALPN)
    }

    @Test("Media send profiles map to Loom profiles")
    func mediaSendProfilesMapToLoomProfiles() {
        let pairs: [(MirageMedia.MirageMediaSendProfile, LoomQueuedUnreliableSendProfile)] = [
            (.interactiveMedia, .interactiveMedia),
            (.proximityInteractiveMedia, .proximityInteractiveMedia),
            (.proximityRealtimeDisplay, .proximityRealtimeDisplay),
            (.proximityRealtimeDisplaySingleLane, .proximityRealtimeDisplaySingleLane),
            (.interactiveAudio, .interactiveAudio),
            (.proximityInteractiveAudio, .proximityInteractiveAudio),
            (.priorityInputRealtime, .priorityInputRealtime),
            (.priorityInputRealtimeSequenced, .priorityInputRealtimeSequenced),
            (.priorityInputContinuous, .priorityInputContinuous),
            (.priorityInputProtected, .priorityInputProtected),
            (.throughputProbe, .throughputProbe),
        ]

        for (mirageProfile, loomProfile) in pairs {
            #expect(MirageConnectivityLoomAdapter.loomMediaSendProfile(from: mirageProfile) == loomProfile)
            #expect(MirageMedia.MirageMediaSendProfile(loomProfile: loomProfile) == mirageProfile)
        }
    }

    @Test("Priority input endpoint adapter mirrors Loom endpoint limits")
    func priorityInputEndpointAdapterMirrorsLoomEndpointLimits() {
        assertPriorityInputEndpointConformance(LoomPriorityInputEndpoint.self)
        #expect(MiragePriorityInputEndpointLimits.maximumPayloadBytes == LoomPriorityInputEndpoint.maximumPayloadBytes)
    }

    @Test("Resolved media paths select Mirage media send profiles")
    func resolvedMediaPathsSelectMirageMediaSendProfiles() {
        #expect(LoomAuthenticatedSession.mirageMediaSendProfile(for: .awdlRadio) == .proximityRealtimeDisplay)
        #expect(LoomAuthenticatedSession.mirageMediaSendProfile(for: .localWiFi) == .interactiveMedia)
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

    @Test("Priority input policy reports availability and fallback")
    func priorityInputPolicyReportsAvailabilityAndFallback() {
        let policy = MirageConnectivity.MiragePriorityInputPolicy()

        let datagramDecision = policy.decision(
            selectedTransport: .udp,
            receiveSemantics: "independent-reliable-unreliable"
        )
        #expect(datagramDecision.isAvailable)
        #expect(datagramDecision.fallback == nil)

        let tcpDecision = policy.decision(
            selectedTransport: .tcp,
            receiveSemantics: "independent-reliable-unreliable"
        )
        #expect(!tcpDecision.isAvailable)
        #expect(tcpDecision.fallback == .reliableControlStream)

        let singleLaneDecision = policy.decision(
            selectedTransport: .quic,
            receiveSemantics: "single-lane"
        )
        #expect(!singleLaneDecision.isAvailable)
        #expect(singleLaneDecision.fallback == .reliableControlStream)

        let disabledDecision = MirageConnectivity.MiragePriorityInputPolicy(
            prefersPriorityInput: false,
            fallback: .queuedUnreliableInput
        )
        .decision(selectedTransport: .udp, receiveSemantics: "independent-reliable-unreliable")
        #expect(!disabledDecision.isAvailable)
        #expect(disabledDecision.fallback == .disabled)
    }

    @Test("Transport path snapshots project Loom path diagnostics")
    func transportPathSnapshotsProjectLoomPathDiagnostics() {
        let loomSnapshot = LoomSessionNetworkPathSnapshot(
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
        let diagnostics = LoomTransportDiagnostics(
            selectedTransportKind: .udp,
            usableDatagramSize: 1_200,
            serviceClass: "interactive-video",
            receiveSemantics: "independent-reliable-unreliable"
        )

        let snapshot = MirageConnectivityLoomAdapter.transportPathSnapshot(
            from: loomSnapshot,
            selectedTransport: .udp,
            targetSource: .bonjour,
            diagnostics: diagnostics,
            dropCounts: MirageConnectivity.MirageConnectivityDropCounts(queueLimit: 2),
            firstControlMessageMs: 10,
            firstMediaPacketMs: 25
        )

        #expect(snapshot?.status == .satisfied)
        #expect(snapshot?.interfaceNames == ["en0"])
        #expect(snapshot?.usesWiFi == true)
        #expect(snapshot?.selectedTransport == .udp)
        #expect(snapshot?.targetSource == .bonjour)
        #expect(snapshot?.receiveSemantics == "independent-reliable-unreliable")
        #expect(snapshot?.serviceClass == .interactiveVideo)
        #expect(snapshot?.usableDatagramSize == 1_200)
        #expect(snapshot?.dropCounts.queueLimit == 2)
        #expect(snapshot?.dropCounts.total == 2)
        #expect(snapshot?.firstControlMessageMs == 10)
        #expect(snapshot?.firstMediaPacketMs == 25)
    }

    @Test("Network path classifier keeps Wi-Fi ahead of passive proximity interfaces")
    func networkPathClassifierKeepsWiFiAheadOfPassiveProximityInterfaces() {
        let snapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
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
    }

    @Test("Network path classifier recognizes scoped proximity endpoints")
    func networkPathClassifierRecognizesScopedProximityEndpoints() {
        let snapshot = MirageConnectivity.MirageNetworkPathClassifier.classify(
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
    }

}

#if os(macOS)
@MainActor
private final class RecordingMirageTrustProvider: MirageTrustProvider {
    let evaluation: MirageTrustEvaluationSnapshot
    private(set) var evaluatedPeers: [MirageAuthenticatedPeerIdentity] = []
    private(set) var grantedPeers: [MirageAuthenticatedPeerIdentity] = []
    private(set) var revokedPeerIDs: [MiragePeerID] = []

    init(evaluation: MirageTrustEvaluationSnapshot) {
        self.evaluation = evaluation
    }

    func evaluateTrust(for peer: MirageAuthenticatedPeerIdentity) async -> MirageTrustDecision {
        evaluatedPeers.append(peer)
        return evaluation.decision
    }

    func evaluateTrustOutcome(for peer: MirageAuthenticatedPeerIdentity) async -> MirageTrustEvaluationSnapshot {
        evaluatedPeers.append(peer)
        return evaluation
    }

    func grantTrust(to peer: MirageAuthenticatedPeerIdentity) async throws {
        grantedPeers.append(peer)
    }

    func revokeTrust(for peerID: MiragePeerID) async throws {
        revokedPeerIDs.append(peerID)
    }
}

private func assertPriorityInputEndpointConformance<T: MiragePriorityInputEndpointProtocol>(_: T.Type) {}
#endif
