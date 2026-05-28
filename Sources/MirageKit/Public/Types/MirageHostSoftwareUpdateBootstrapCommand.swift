//
//  MirageHostSoftwareUpdateBootstrapCommand.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/25/26.
//

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

    public func peerIdentity(authenticatedBy peer: LoomBootstrapControlPeer) -> LoomPeerIdentity {
        LoomPeerIdentity(
            deviceID: clientDeviceID,
            name: clientName,
            deviceType: clientDeviceType,
            iCloudUserID: clientICloudUserID,
            identityKeyID: peer.keyID,
            identityPublicKey: peer.publicKey,
            isIdentityAuthenticated: true,
            advertisementMetadata: advertisementMetadata,
            endpoint: peer.endpoint
        )
    }
}
