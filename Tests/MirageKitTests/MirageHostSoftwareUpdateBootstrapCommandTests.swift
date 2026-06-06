//
//  MirageHostSoftwareUpdateBootstrapCommandTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/25/26.
//

import Foundation
import CryptoKit
import Loom
import MirageBootstrapShared
import MirageIdentity
import MirageKit
import Testing

@Suite("Mirage Host Software Update Bootstrap Command")
struct MirageHostSoftwareUpdateBootstrapCommandTests {
    @Test("Command preserves hello identity and authenticated bootstrap peer")
    func commandPreservesHelloIdentityAndAuthenticatedBootstrapPeer() throws {
        let deviceID = try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000001"))
        let hello = LoomSessionHelloRequest(
            deviceID: deviceID,
            deviceName: "Ethan's iPad",
            deviceType: .iPad,
            advertisement: LoomPeerAdvertisement(
                protocolVersion: Int(MirageKit.controlProtocolVersion),
                deviceID: deviceID,
                identityKeyID: "client-key",
                deviceType: .iPad,
                metadata: ["mirage.client": "1"]
            ),
            iCloudUserID: "icloud-user"
        )
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let keyID = MirageIdentityKeyID.keyID(for: publicKey)
        let bootstrapPeer = MirageBootstrapAuthenticatedPeer(
            keyID: keyID,
            publicKey: publicKey,
            endpointDescription: "127.0.0.1"
        )
        let peer = LoomBootstrapControlPeer(
            keyID: keyID,
            publicKey: publicKey,
            endpoint: "127.0.0.1"
        )

        let command = MirageHostSoftwareUpdateBootstrapCommand(helloRequest: hello)
        let decoded = try JSONDecoder().decode(
            MirageHostSoftwareUpdateBootstrapCommand.self,
            from: JSONEncoder().encode(command)
        )
        let identity = decoded.peerIdentity(authenticatedBy: peer)
        let authenticatedIdentity = decoded.authenticatedPeerIdentity(authenticatedBy: bootstrapPeer)
        let loomAuthenticatedIdentity = decoded.authenticatedPeerIdentity(authenticatedBy: peer)

        #expect(decoded.clientDeviceID == deviceID)
        #expect(decoded.clientName == "Ethan's iPad")
        #expect(decoded.clientDeviceType == .iPad)
        #expect(decoded.clientICloudUserID == "icloud-user")
        #expect(decoded.advertisementMetadata == ["mirage.client": "1"])
        #expect(identity.deviceID == deviceID)
        #expect(identity.identityKeyID == keyID)
        #expect(identity.identityPublicKey == publicKey)
        #expect(identity.isIdentityAuthenticated)
        #expect(identity.endpoint == "127.0.0.1")
        #expect(authenticatedIdentity.deviceID == deviceID)
        #expect(authenticatedIdentity.identityKeyID == keyID)
        #expect(authenticatedIdentity.identityPublicKey == publicKey)
        #expect(authenticatedIdentity.hasConsistentAuthenticatedIdentityKey)
        #expect(loomAuthenticatedIdentity == authenticatedIdentity)
    }
}
