//
//  ClientHelloHandshakeStateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Network
import Testing

@Suite("Client Hello Handshake State")
struct ClientHelloHandshakeStateTests {
    @MainActor
    @Test("Accepted hello canonicalizes connected host and transitions to connected")
    func acceptedHelloCanonicalizesConnectedHost() throws {
        let provisionalHostID = UUID()
        let acceptedHostID = UUID()
        let port = try #require(NWEndpoint.Port(rawValue: 9_848))
        let provisionalAdvertisement = LoomPeerAdvertisement(
            protocolVersion: Int(Loom.protocolVersion),
            deviceID: provisionalHostID,
            identityKeyID: "bonjour-key",
            deviceType: .mac,
            modelIdentifier: "Mac16,1",
            iconName: "com.apple.macbookpro-16-silver",
            machineFamily: "macBook",
            metadata: ["source": "bonjour"]
        )
        let provisionalHost = LoomPeer(
            id: provisionalHostID,
            name: "Bonjour Host",
            deviceType: .mac,
            endpoint: .hostPort(host: NWEndpoint.Host("bonjour.local"), port: port),
            advertisement: provisionalAdvertisement
        )
        let service = MirageClientService(deviceName: "Test Device")
        service.connectedHost = provisionalHost
        service.connectionState = .handshaking(host: provisionalHost.name)
        service.pendingHelloNonce = "req-nonce"
        service.isAwaitingManualApproval = true

        let response = HelloResponseMessage(
            accepted: true,
            hostID: acceptedHostID,
            hostName: "Accepted Host",
            requiresAuth: false,
            dataPort: 9_848,
            negotiation: MirageProtocolNegotiation.clientHello(
                protocolVersion: Int(MirageKit.protocolVersion),
                supportedFeatures: mirageSupportedFeatures
            ),
            requestNonce: "req-nonce",
            mediaEncryptionEnabled: true,
            udpRegistrationToken: Data(repeating: 0xAB, count: MirageMediaSecurity.registrationTokenLength),
            identity: MirageIdentityEnvelope(
                keyID: "accepted-key",
                publicKey: Data([0x01, 0x02]),
                timestampMs: 1_234_567_890,
                nonce: "host-nonce",
                signature: Data([0x03, 0x04])
            )
        )

        let acceptedHost = service.finalizeAcceptedHelloResponse(
            response,
            hostIdentityKeyID: "accepted-key"
        )

        #expect(service.connectionState == .connected(host: "Accepted Host"))
        #expect(service.connectedHostIdentityKeyID == "accepted-key")
        #expect(service.pendingHelloNonce == nil)
        #expect(service.hasReceivedHelloResponse == true)
        #expect(service.isAwaitingManualApproval == false)
        #expect(acceptedHost.id == acceptedHostID)
        #expect(service.connectedHost?.id == acceptedHostID)
        #expect(service.connectedHost?.name == "Accepted Host")
        #expect(service.connectedHost?.deviceType == .mac)
        #expect(service.connectedHost?.advertisement.deviceID == acceptedHostID)
        #expect(service.connectedHost?.advertisement.identityKeyID == "accepted-key")
        #expect(service.connectedHost?.advertisement.modelIdentifier == "Mac16,1")
        #expect(service.connectedHost?.advertisement.iconName == "com.apple.macbookpro-16-silver")
        #expect(service.connectedHost?.advertisement.machineFamily == "macBook")
        #expect(service.connectedHost?.advertisement.metadata["source"] == "bonjour")
    }

    @MainActor
    @Test("Manual approval wait indicator only activates during handshaking")
    func manualApprovalWaitIndicatorOnlyActivatesDuringHandshaking() {
        #expect(
            MirageClientService.shouldActivateManualApprovalWaitIndicator(
                hasReceivedHelloResponse: false,
                connectionState: .handshaking(host: "Host")
            )
        )
        #expect(
            !MirageClientService.shouldActivateManualApprovalWaitIndicator(
                hasReceivedHelloResponse: false,
                connectionState: .connecting
            )
        )
        #expect(
            !MirageClientService.shouldActivateManualApprovalWaitIndicator(
                hasReceivedHelloResponse: false,
                connectionState: .connected(host: "Host")
            )
        )
        #expect(
            !MirageClientService.shouldActivateManualApprovalWaitIndicator(
                hasReceivedHelloResponse: true,
                connectionState: .handshaking(host: "Host")
            )
        )
    }
}
