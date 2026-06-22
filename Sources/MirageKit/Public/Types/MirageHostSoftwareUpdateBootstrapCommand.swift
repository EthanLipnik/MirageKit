//
//  MirageHostSoftwareUpdateBootstrapCommand.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/25/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import Foundation
import Loom

/// Mirage bootstrap-control commands.
public enum MirageBootstrapControlCommandIdentifier {
    /// Requests an authenticated host software-update install.
    public static let hostSoftwareUpdateInstall = "com.ethanlipnik.Mirage.host-software-update.install"
}

/// Body for the out-of-band host software-update install command.
public struct MirageHostSoftwareUpdateBootstrapCommand: Codable, Equatable, Sendable {
    public let clientDeviceID: UUID
    public let clientName: String
    public let clientDeviceType: DeviceType
    public let clientICloudUserID: String?
    public let advertisementMetadata: [String: String]

    public init(
        clientDeviceID: UUID,
        clientName: String,
        clientDeviceType: DeviceType,
        clientICloudUserID: String?,
        advertisementMetadata: [String: String]
    ) {
        self.clientDeviceID = clientDeviceID
        self.clientName = clientName
        self.clientDeviceType = clientDeviceType
        self.clientICloudUserID = clientICloudUserID
        self.advertisementMetadata = advertisementMetadata
    }

    public init(helloRequest: LoomSessionHelloRequest) {
        self.init(
            clientDeviceID: helloRequest.deviceID,
            clientName: helloRequest.deviceName,
            clientDeviceType: helloRequest.deviceType,
            clientICloudUserID: helloRequest.iCloudUserID,
            advertisementMetadata: helloRequest.advertisement.metadata
        )
    }

    public func authenticatedPeerIdentity(
        authenticatedBy peer: MirageBootstrapAuthenticatedPeer
    ) -> MirageAuthenticatedPeerIdentity {
        MirageAuthenticatedPeerIdentity(
            deviceID: clientDeviceID,
            displayName: clientName,
            iCloudUserID: clientICloudUserID,
            identityKeyID: peer.keyID,
            identityPublicKey: peer.publicKey,
            isIdentityAuthenticated: true,
            endpointDescription: peer.endpointDescription
        )
    }

    public func authenticatedPeerIdentity(
        authenticatedBy peer: LoomBootstrapControlPeer
    ) -> MirageAuthenticatedPeerIdentity {
        authenticatedPeerIdentity(
            authenticatedBy: MirageBootstrapAuthenticatedPeer(
                keyID: peer.keyID,
                publicKey: peer.publicKey,
                endpointDescription: peer.endpoint
            )
        )
    }

    public func peerIdentity(authenticatedBy peer: LoomBootstrapControlPeer) -> LoomPeerIdentity {
        let authenticatedIdentity = authenticatedPeerIdentity(authenticatedBy: peer)
        return LoomPeerIdentity(
            deviceID: authenticatedIdentity.deviceID,
            name: authenticatedIdentity.displayName,
            deviceType: clientDeviceType,
            iCloudUserID: authenticatedIdentity.iCloudUserID,
            identityKeyID: authenticatedIdentity.identityKeyID,
            identityPublicKey: authenticatedIdentity.identityPublicKey,
            isIdentityAuthenticated: true,
            advertisementMetadata: advertisementMetadata,
            endpoint: authenticatedIdentity.endpointDescription ?? peer.endpoint
        )
    }
}
