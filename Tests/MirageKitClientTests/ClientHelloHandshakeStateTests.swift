//
//  ClientHelloHandshakeStateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

@testable import Loom
@testable import MirageKit
@testable import MirageKitClient
import Network
import Testing

@Suite("Client Bootstrap State")
struct ClientHelloHandshakeStateTests {
    @MainActor
    @Test("Accepted bootstrap canonicalizes connected host and transitions to connected")
    func acceptedBootstrapCanonicalizesConnectedHost() async throws {
        let provisionalHostID = UUID()
        let acceptedHostID = UUID()
        let port = try #require(NWEndpoint.Port(rawValue: 9_848))
        let udpPort = try #require(NWEndpoint.Port(rawValue: 61_020))
        let provisionalAdvertisement = LoomPeerAdvertisement(
            protocolVersion: Int(Loom.protocolVersion),
            deviceID: provisionalHostID,
            identityKeyID: "bonjour-key",
            deviceType: .mac,
            modelIdentifier: "Mac16,1",
            iconName: "com.apple.macbookpro-16-silver",
            machineFamily: "macBook",
            hostName: "bonjour.local",
            directTransports: [
                LoomDirectTransportAdvertisement(transportKind: .udp, port: udpPort.rawValue),
            ],
            metadata: ["source": "bonjour"]
        )
        let provisionalHost = LoomPeer(
            id: provisionalHostID,
            name: "Bonjour Host",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("bonjour.local"), port: port),
            advertisement: provisionalAdvertisement,
            resolvedAddresses: [.ipv4(IPv4Address("192.168.50.81")!)]
        )
        let service = MirageClientService(deviceName: "Test Device")
        service.connectedHost = provisionalHost
        service.connectionState = .handshaking(host: provisionalHost.name)
        service.isAwaitingManualApproval = true

        let response = MirageSessionBootstrapResponse(
            accepted: true,
            hostID: acceptedHostID,
            hostName: "Accepted Host",
            selectedFeatures: mirageSupportedFeatures,
            mediaEncryptionEnabled: true,
            udpRegistrationToken: Data(repeating: 0xAB, count: MirageMediaSecurity.registrationTokenLength)
        )

        let acceptedHost = await service.finalizeAcceptedBootstrap(
            response,
            hostIdentityKeyID: "accepted-key"
        )

        #expect(service.connectionState == .connected(host: "Accepted Host"))
        #expect(service.connectedHostIdentityKeyID == "accepted-key")
        #expect(service.hasCompletedBootstrap == true)
        #expect(service.isAwaitingManualApproval == false)
        #expect(acceptedHost.id == LoomPeerID(deviceID: acceptedHostID))
        #expect(service.connectedHost?.id == LoomPeerID(deviceID: acceptedHostID))
        #expect(service.connectedHost?.name == "Accepted Host")
        #expect(service.connectedHost?.deviceType == .mac)
        #expect(service.connectedHost?.advertisement.deviceID == acceptedHostID)
        #expect(service.connectedHost?.advertisement.identityKeyID == "accepted-key")
        #expect(service.connectedHost?.advertisement.modelIdentifier == "Mac16,1")
        #expect(service.connectedHost?.advertisement.iconName == "com.apple.macbookpro-16-silver")
        #expect(service.connectedHost?.advertisement.machineFamily == "macBook")
        #expect(service.connectedHost?.advertisement.hostName == "bonjour.local")
        #expect(service.connectedHost?.advertisement.directTransports == provisionalAdvertisement.directTransports)
        #expect(service.connectedHost?.advertisement.metadata["source"] == "bonjour")
        #expect(service.connectedHost?.resolvedAddresses == provisionalHost.resolvedAddresses)
    }

    @MainActor
    @Test("Loom transport parameters use best-effort service class for control connections")
    func loomTransportParametersUseBestEffortServiceClass() throws {
        let tcpParameters = try LoomTransportParametersFactory.makeParameters(
            for: .tcp,
            enablePeerToPeer: false
        )
        let quicParameters = try LoomTransportParametersFactory.makeParameters(
            for: .quic,
            enablePeerToPeer: false,
            quicALPN: ["mirage-v2"]
        )

        #expect(tcpParameters.serviceClass == .bestEffort)
        #expect(quicParameters.serviceClass == .bestEffort)
    }

    @MainActor
    @Test("Bootstrap response wait times out with an explicit handshake error")
    func bootstrapResponseWaitTimesOutWithExplicitHandshakeError() async {
        let service = MirageClientService(deviceName: "Test Device")
        let stream = AsyncStream<Data> { _ in }

        do {
            try await service.receiveSingleControlMessage(
                from: stream,
                timeout: .milliseconds(50),
                timeoutMessage: "Timed out waiting for host bootstrap response from Test Host"
            )
            Issue.record("Expected bootstrap response wait to time out.")
        } catch let MirageError.protocolError(message) {
            #expect(message == "Timed out waiting for host bootstrap response from Test Host")
        } catch {
            Issue.record("Unexpected timeout error: \(error.localizedDescription)")
        }
    }

    @MainActor
    @Test("Bootstrap response timeout leaves room for manual host approval")
    func bootstrapResponseTimeoutAllowsManualHostApproval() {
        let service = MirageClientService(deviceName: "Test Device")

        #expect(service.bootstrapResponseTimeout >= .seconds(30))
        #expect(service.bootstrapResponseTimeout > service.controlSessionConnectTimeout)
        #expect(service.trustPendingControlSessionConnectTimeout > service.controlSessionConnectTimeout)
    }

    @MainActor
    @Test("Trust-pending bootstrap phase extends the control-session timeout budget")
    func trustPendingBootstrapPhaseExtendsControlSessionTimeoutBudget() async {
        let tracker = ConnectSessionBootstrapProgressTracker()
        let base = ContinuousClock.now

        await tracker.record(
            LoomAuthenticatedSessionBootstrapProgress(phase: .trustPendingApproval),
            now: base
        )

        let beforeDeadline = await tracker.shouldTimeOut(
            now: base + .seconds(40),
            initialTimeout: .seconds(30),
            activePhaseIdleTimeout: .seconds(30),
            trustPendingIdleTimeout: .seconds(90),
            absoluteTimeout: .seconds(30),
            trustPendingAbsoluteTimeout: .seconds(90)
        )
        let afterDeadline = await tracker.shouldTimeOut(
            now: base + .seconds(95),
            initialTimeout: .seconds(30),
            activePhaseIdleTimeout: .seconds(30),
            trustPendingIdleTimeout: .seconds(90),
            absoluteTimeout: .seconds(30),
            trustPendingAbsoluteTimeout: .seconds(90)
        )

        #expect(beforeDeadline == false)
        #expect(afterDeadline == true)
    }
}
