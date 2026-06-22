//
//  MirageConnectivityModels.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageIdentity
import MirageWire

/// Direct transport protocols Mirage can request without exposing Loom types.
public enum MirageTransportKind: String, Sendable, Codable, Hashable, CaseIterable {
    case tcp
    case quic
    case udp
}

/// Broad direct-path categories used by Mirage policy.
public enum MirageDirectPathKind: String, Sendable, Codable, Hashable, CaseIterable {
    case wired
    case wifi
    case proximityWireless
    case other
}


/// Direct transport endpoint advertised by a Mirage peer.
public struct MirageDirectTransportDescriptor: Sendable, Codable, Hashable {
    /// Direct transport protocol.
    public let kind: MirageTransportKind

    /// Listening port for this direct transport.
    public let port: UInt16

    /// Broad path hint for this transport, when known.
    public let pathKind: MirageDirectPathKind?

    /// Creates a direct transport descriptor.
    public init(
        kind: MirageTransportKind,
        port: UInt16,
        pathKind: MirageDirectPathKind? = nil
    ) {
        self.kind = kind
        self.port = port
        self.pathKind = pathKind
    }
}

/// Product-safe reachability status for an active connectivity path.
public enum MirageTransportPathStatus: String, Sendable, Codable, Hashable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

/// Source of the selected connectivity target.
public enum MirageConnectivityTargetSource: String, Sendable, Codable, Hashable, CaseIterable {
    case bonjour
    case remoteSignaling
    case rememberedDirectEndpoint
    case manual
    case unknown
}

/// Datagram service class requested by Mirage policy.
public enum MirageDatagramServiceClass: String, Sendable, Codable, Hashable, CaseIterable {
    case bestEffort
    case background
    case interactiveVideo
    case interactiveVoice
    case responsiveData
    case signaling
}


/// Mirage-owned projection of a discovered peer.
public struct MiragePeerDescriptor: Identifiable, Sendable, Codable, Hashable {
    /// Stable peer identity.
    public let id: MiragePeerID

    /// Display name advertised by the peer.
    public let name: String

    /// Broad device family.
    public let deviceType: MirageDeviceType?

    /// Hostname or endpoint label suitable for diagnostics.
    public let endpointDescription: String?

    /// Mirage protocol version advertised by the peer.
    public let protocolVersion: Int?

    /// Identity key identifier advertised by the peer.
    public let identityKeyID: String?

    /// Direct transports advertised by the peer.
    public let directTransports: [MirageDirectTransportDescriptor]

    /// Connectivity target source that produced this descriptor.
    public let targetSource: MirageConnectivityTargetSource

    /// Creates a peer descriptor.
    public init(
        id: MiragePeerID,
        name: String,
        deviceType: MirageDeviceType? = nil,
        endpointDescription: String? = nil,
        protocolVersion: Int? = nil,
        identityKeyID: String? = nil,
        directTransports: [MirageDirectTransportDescriptor] = [],
        targetSource: MirageConnectivityTargetSource = .unknown
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.endpointDescription = endpointDescription
        self.protocolVersion = protocolVersion
        self.identityKeyID = identityKeyID
        self.directTransports = directTransports
        self.targetSource = targetSource
    }

    /// Creates a peer descriptor from a device identity.
    public init(
        deviceID: UUID,
        appID: String? = nil,
        name: String,
        deviceType: MirageDeviceType? = nil,
        endpointDescription: String? = nil,
        protocolVersion: Int? = nil,
        identityKeyID: String? = nil,
        directTransports: [MirageDirectTransportDescriptor] = [],
        targetSource: MirageConnectivityTargetSource = .unknown
    ) {
        self.init(
            id: MiragePeerID(deviceID: deviceID, appID: appID),
            name: name,
            deviceType: deviceType,
            endpointDescription: endpointDescription,
            protocolVersion: protocolVersion,
            identityKeyID: identityKeyID,
            directTransports: directTransports,
            targetSource: targetSource
        )
    }
}

/// Mirage-owned projection of a host peer.
public struct MirageHostDescriptor: Identifiable, Sendable, Codable, Hashable {
    /// Stable host identity.
    public var id: MiragePeerID { peer.id }

    /// Peer descriptor backing this host.
    public let peer: MiragePeerDescriptor

    /// Current host session availability when known.
    public let sessionAvailability: MirageHostSessionAvailability?

    /// Whether the host is advertising capacity for a new client session.
    public let acceptsNewConnections: Bool?

    /// Whether the host advertises off-LAN reachability.
    public let allowsRemoteAccess: Bool?

    /// Creates a host descriptor.
    public init(
        peer: MiragePeerDescriptor,
        sessionAvailability: MirageHostSessionAvailability? = nil,
        acceptsNewConnections: Bool? = nil,
        allowsRemoteAccess: Bool? = nil
    ) {
        self.peer = peer
        self.sessionAvailability = sessionAvailability
        self.acceptsNewConnections = acceptsNewConnections
        self.allowsRemoteAccess = allowsRemoteAccess
    }
}

/// Drop counts reported by the selected queued-unreliable transport.
public struct MirageConnectivityDropCounts: Sendable, Codable, Hashable {
    public let deadlineExpired: UInt64
    public let queueLimit: UInt64
    public let superseded: UInt64
    public let unsupportedTransport: UInt64
    public let closed: UInt64

    /// Creates transport drop counts.
    public init(
        deadlineExpired: UInt64 = 0,
        queueLimit: UInt64 = 0,
        superseded: UInt64 = 0,
        unsupportedTransport: UInt64 = 0,
        closed: UInt64 = 0
    ) {
        self.deadlineExpired = deadlineExpired
        self.queueLimit = queueLimit
        self.superseded = superseded
        self.unsupportedTransport = unsupportedTransport
        self.closed = closed
    }

    /// Total reported drops.
    public var total: UInt64 {
        deadlineExpired + queueLimit + superseded + unsupportedTransport + closed
    }
}

/// Product-safe snapshot of the active connectivity path and transport diagnostics.
public struct MirageTransportPathSnapshot: Sendable, Codable, Hashable {
    public let status: MirageTransportPathStatus
    public let interfaceNames: [String]
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let usesWiFi: Bool
    public let usesWiredEthernet: Bool
    public let usesCellular: Bool
    public let usesLoopback: Bool
    public let usesOther: Bool
    public let selectedTransport: MirageTransportKind?
    public let targetSource: MirageConnectivityTargetSource
    public let receiveSemantics: String?
    public let serviceClass: MirageDatagramServiceClass?
    public let usableDatagramSize: Int?
    public let queueDwellP50Ms: Double?
    public let queueDwellP95Ms: Double?
    public let queueDwellP99Ms: Double?
    public let queuedBytes: UInt64?
    public let outstandingBytes: UInt64?
    public let dropCounts: MirageConnectivityDropCounts
    public let firstControlMessageMs: Double?
    public let firstMediaPacketMs: Double?

    /// Creates a transport path snapshot.
    public init(
        status: MirageTransportPathStatus,
        interfaceNames: [String] = [],
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        supportsIPv4: Bool = false,
        supportsIPv6: Bool = false,
        usesWiFi: Bool = false,
        usesWiredEthernet: Bool = false,
        usesCellular: Bool = false,
        usesLoopback: Bool = false,
        usesOther: Bool = false,
        selectedTransport: MirageTransportKind? = nil,
        targetSource: MirageConnectivityTargetSource = .unknown,
        receiveSemantics: String? = nil,
        serviceClass: MirageDatagramServiceClass? = nil,
        usableDatagramSize: Int? = nil,
        queueDwellP50Ms: Double? = nil,
        queueDwellP95Ms: Double? = nil,
        queueDwellP99Ms: Double? = nil,
        queuedBytes: UInt64? = nil,
        outstandingBytes: UInt64? = nil,
        dropCounts: MirageConnectivityDropCounts = MirageConnectivityDropCounts(),
        firstControlMessageMs: Double? = nil,
        firstMediaPacketMs: Double? = nil
    ) {
        self.status = status
        self.interfaceNames = interfaceNames
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.usesWiFi = usesWiFi
        self.usesWiredEthernet = usesWiredEthernet
        self.usesCellular = usesCellular
        self.usesLoopback = usesLoopback
        self.usesOther = usesOther
        self.selectedTransport = selectedTransport
        self.targetSource = targetSource
        self.receiveSemantics = receiveSemantics
        self.serviceClass = serviceClass
        self.usableDatagramSize = usableDatagramSize
        self.queueDwellP50Ms = queueDwellP50Ms
        self.queueDwellP95Ms = queueDwellP95Ms
        self.queueDwellP99Ms = queueDwellP99Ms
        self.queuedBytes = queuedBytes
        self.outstandingBytes = outstandingBytes
        self.dropCounts = dropCounts
        self.firstControlMessageMs = firstControlMessageMs
        self.firstMediaPacketMs = firstMediaPacketMs
    }
}
