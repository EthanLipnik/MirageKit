//
//  MirageHostService+Types.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Public host service supporting types.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation
import Loom

#if os(macOS)
/// Connection path class for an accepted Mirage host client.
public enum MirageHostConnectionOrigin: String, Sendable {
    /// Client connected over the local authenticated Loom session path.
    case local

    /// Client connected through the direct remote transport path.
    case remote

    /// Whether this origin uses Mirage's direct remote transport.
    public var isRemote: Bool {
        self == .remote
    }
}

/// Public identity and transport metadata for a client connected to the host.
public struct MirageConnectedClient: Identifiable, Sendable {
    /// Stable device identifier from the authenticated peer identity.
    public let id: UUID

    /// Human-readable peer name advertised by the client.
    public let name: String

    /// Client device family advertised during bootstrap.
    public let deviceType: DeviceType

    /// Product-safe device family advertised during bootstrap.
    public let mirageDeviceType: MirageIdentity.MirageDeviceType

    /// Date when the host accepted the client session.
    public let connectedAt: Date

    /// Optional signed identity key ID used for trust continuity.
    public let identityKeyID: String?

    /// Product-safe authenticated peer identity captured during connection setup.
    public let authenticatedPeerIdentity: MirageAuthenticatedPeerIdentity

    /// Product-safe trust evaluation captured during connection setup, if available.
    public let trustEvaluation: MirageTrustEvaluationSnapshot?

    /// Whether this connection was accepted through automatic trust.
    public let autoTrustGranted: Bool

    /// Transport path used by the accepted connection.
    public let connectionOrigin: MirageHostConnectionOrigin

    /// Full Loom peer advertisement captured during connection setup.
    public let peerAdvertisement: LoomPeerAdvertisement

    /// Creates a connected-client snapshot from the authenticated peer metadata.
    public init(
        id: UUID,
        name: String,
        deviceType: DeviceType,
        mirageDeviceType: MirageIdentity.MirageDeviceType? = nil,
        connectedAt: Date,
        identityKeyID: String? = nil,
        authenticatedPeerIdentity: MirageAuthenticatedPeerIdentity? = nil,
        trustEvaluation: MirageTrustEvaluationSnapshot? = nil,
        autoTrustGranted: Bool = false,
        connectionOrigin: MirageHostConnectionOrigin = .local,
        peerAdvertisement: LoomPeerAdvertisement = LoomPeerAdvertisement()
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.mirageDeviceType = mirageDeviceType ?? Self.mirageDeviceType(from: deviceType)
        self.connectedAt = connectedAt
        self.identityKeyID = identityKeyID
        self.authenticatedPeerIdentity = authenticatedPeerIdentity ?? MirageAuthenticatedPeerIdentity(
            deviceID: id,
            displayName: name,
            deviceType: self.mirageDeviceType,
            identityKeyID: identityKeyID,
            isIdentityAuthenticated: identityKeyID != nil
        )
        self.trustEvaluation = trustEvaluation
        self.autoTrustGranted = autoTrustGranted
        self.connectionOrigin = connectionOrigin
        self.peerAdvertisement = peerAdvertisement
    }

    static func mirageDeviceType(from deviceType: DeviceType) -> MirageIdentity.MirageDeviceType {
        switch deviceType {
        case .mac:
            .mac
        case .iPad:
            .iPad
        case .iPhone:
            .iPhone
        case .vision:
            .vision
        case .unknown:
            .unknown
        }
    }
}

/// Logical host stream bound to a window and the client receiving it.
public struct MirageStreamSession: Identifiable, Sendable {
    /// Stream identifier used on the control and media paths.
    public let id: StreamID

    /// Source window currently associated with the stream.
    public let window: MirageMedia.MirageWindow

    /// Client that owns the stream session.
    public let client: MirageConnectedClient
}
#endif
