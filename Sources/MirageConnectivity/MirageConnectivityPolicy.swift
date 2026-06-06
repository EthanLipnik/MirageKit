//
//  MirageConnectivityPolicy.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore
import MirageMedia

/// Product-owned policy for ranking direct connection candidates.
public struct MirageDirectConnectionPolicy: Sendable, Codable, Hashable {
    /// Preferred order for local direct path categories.
    public var preferredLocalPathOrder: [MirageDirectPathKind]

    /// Preferred order for direct transport protocols.
    public var preferredTransportOrder: [MirageTransportKind]

    /// Optional host override for local discovery records.
    public var localDiscoveryHostOverride: String?

    /// Whether nearby direct candidates should be raced.
    public var racesLocalCandidates: Bool

    /// Whether remote direct candidates should be raced.
    public var racesRemoteCandidates: Bool

    /// Creates a direct connection policy.
    public init(
        preferredLocalPathOrder: [MirageDirectPathKind] = [.wired, .wifi, .proximityWireless, .other],
        preferredTransportOrder: [MirageTransportKind] = [.udp, .quic, .tcp],
        localDiscoveryHostOverride: String? = nil,
        racesLocalCandidates: Bool = true,
        racesRemoteCandidates: Bool = true
    ) {
        self.preferredLocalPathOrder = preferredLocalPathOrder
        self.preferredTransportOrder = preferredTransportOrder
        self.localDiscoveryHostOverride = localDiscoveryHostOverride
        self.racesLocalCandidates = racesLocalCandidates
        self.racesRemoteCandidates = racesRemoteCandidates
    }

    /// Default Mirage direct connection policy.
    public static let `default` = MirageDirectConnectionPolicy()
}

/// Product-owned network configuration for discovery and session transport behavior.
public struct MirageNetworkConfiguration: Sendable, Codable, Hashable {
    public var serviceType: String
    public var controlPort: UInt16
    public var dataPort: UInt16
    public var quicPort: UInt16
    public var udpPort: UInt16
    public var overlayProbePort: UInt16?
    public var maxPacketSize: Int
    public var enableBonjour: Bool
    public var enablePeerToPeer: Bool
    public var requireEncryptedMediaOnLocalNetwork: Bool
    public var enabledDirectTransports: Set<MirageTransportKind>
    public var directConnectionPolicy: MirageDirectConnectionPolicy
    public var quicALPN: [String]
    public var datagramServiceClass: MirageDatagramServiceClass

    /// Creates a network configuration.
    public init(
        serviceType: String = MirageNetworkDefaults.serviceType,
        controlPort: UInt16 = MirageNetworkDefaults.directTCPPort,
        dataPort: UInt16 = MirageNetworkDefaults.directTCPPort,
        quicPort: UInt16 = MirageNetworkDefaults.directQUICPort,
        udpPort: UInt16 = MirageNetworkDefaults.directUDPPort,
        overlayProbePort: UInt16? = MirageNetworkDefaults.overlayProbePort,
        maxPacketSize: Int = 1_200,
        enableBonjour: Bool = true,
        enablePeerToPeer: Bool = true,
        requireEncryptedMediaOnLocalNetwork: Bool = false,
        enabledDirectTransports: Set<MirageTransportKind> = Set(MirageTransportKind.allCases),
        directConnectionPolicy: MirageDirectConnectionPolicy = .default,
        quicALPN: [String] = ["mirage-v2"],
        datagramServiceClass: MirageDatagramServiceClass = .interactiveVideo
    ) {
        self.serviceType = serviceType
        self.controlPort = controlPort
        self.dataPort = dataPort
        self.quicPort = quicPort
        self.udpPort = udpPort
        self.overlayProbePort = overlayProbePort
        self.maxPacketSize = maxPacketSize
        self.enableBonjour = enableBonjour
        self.enablePeerToPeer = enablePeerToPeer
        self.requireEncryptedMediaOnLocalNetwork = requireEncryptedMediaOnLocalNetwork
        self.enabledDirectTransports = enabledDirectTransports
        self.directConnectionPolicy = directConnectionPolicy
        self.quicALPN = quicALPN
        self.datagramServiceClass = datagramServiceClass
    }

    /// Default Mirage network configuration.
    public static let `default` = MirageNetworkConfiguration()
}

/// Priority-input fallback used when a first-class input lane is unavailable.
public enum MiragePriorityInputFallback: String, Sendable, Codable, Hashable, CaseIterable {
    case reliableControlStream
    case queuedUnreliableInput
    case disabled
}

/// Runtime priority-input decision in Mirage terms.
public struct MiragePriorityInputDecision: Sendable, Codable, Hashable {
    /// Whether a first-class priority input lane is available.
    public let isAvailable: Bool

    /// Fallback selected when `isAvailable` is false.
    public let fallback: MiragePriorityInputFallback?

    /// Diagnostic reason for the decision.
    public let reason: String?

    /// Creates a priority-input decision.
    public init(
        isAvailable: Bool,
        fallback: MiragePriorityInputFallback? = nil,
        reason: String? = nil
    ) {
        self.isAvailable = isAvailable
        self.fallback = fallback
        self.reason = reason
    }
}

/// Product-owned policy for priority input.
public struct MiragePriorityInputPolicy: Sendable, Codable, Hashable {
    /// Whether Mirage should prefer a first-class priority input lane.
    public var prefersPriorityInput: Bool

    /// Fallback when the selected transport cannot provide priority input.
    public var fallback: MiragePriorityInputFallback

    /// Creates a priority-input policy.
    public init(
        prefersPriorityInput: Bool = true,
        fallback: MiragePriorityInputFallback = .reliableControlStream
    ) {
        self.prefersPriorityInput = prefersPriorityInput
        self.fallback = fallback
    }

    /// Resolves availability for the selected transport and receive semantics.
    public func decision(
        selectedTransport: MirageTransportKind?,
        receiveSemantics: String?
    ) -> MiragePriorityInputDecision {
        guard prefersPriorityInput else {
            return MiragePriorityInputDecision(
                isAvailable: false,
                fallback: .disabled,
                reason: "Priority input disabled by policy"
            )
        }
        guard selectedTransport == .udp || selectedTransport == .quic else {
            return MiragePriorityInputDecision(
                isAvailable: false,
                fallback: fallback,
                reason: "Priority input requires a datagram transport"
            )
        }
        guard receiveSemantics != "single-lane" else {
            return MiragePriorityInputDecision(
                isAvailable: false,
                fallback: fallback,
                reason: "Priority input requires independent receive lanes"
            )
        }
        return MiragePriorityInputDecision(isAvailable: true)
    }
}

/// Connectivity policy selected for a stream recipe.
public struct MirageConnectivityPolicy: Sendable, Codable, Hashable {
    public var networkConfiguration: MirageNetworkConfiguration
    public var mediaSendProfile: MirageMedia.MirageMediaSendProfile
    public var audioSendProfile: MirageMedia.MirageMediaSendProfile
    public var priorityInputPolicy: MiragePriorityInputPolicy
    public var delegatesConnectionRacingToLoom: Bool

    /// Creates a connectivity policy.
    public init(
        networkConfiguration: MirageNetworkConfiguration = .default,
        mediaSendProfile: MirageMedia.MirageMediaSendProfile = .interactiveMedia,
        audioSendProfile: MirageMedia.MirageMediaSendProfile = .interactiveAudio,
        priorityInputPolicy: MiragePriorityInputPolicy = MiragePriorityInputPolicy(),
        delegatesConnectionRacingToLoom: Bool = true
    ) {
        self.networkConfiguration = networkConfiguration
        self.mediaSendProfile = mediaSendProfile
        self.audioSendProfile = audioSendProfile
        self.priorityInputPolicy = priorityInputPolicy
        self.delegatesConnectionRacingToLoom = delegatesConnectionRacingToLoom
    }
}

/// Loom-free session interface exposed by the Mirage connectivity boundary.
public protocol MirageConnectivitySession: Sendable {
    /// Stable connectivity-session identity.
    var id: UUID { get }

    /// Selected transport kind.
    var selectedTransport: MirageTransportKind { get async }

    /// Latest projected transport path snapshot.
    var transportPathSnapshot: MirageTransportPathSnapshot? { get async }

    /// Projected connected peer when available.
    var peerDescriptor: MiragePeerDescriptor? { get async }

    /// Observes projected path snapshots.
    func makeTransportPathObserver() async -> AsyncStream<MirageTransportPathSnapshot>

    /// Closes the underlying connectivity session.
    func close() async throws
}
