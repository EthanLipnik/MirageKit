//
//  MessageTypes+Connection.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Connection Messages

package enum MirageSessionBootstrapRejectionReason: String, Codable, Sendable {
    case protocolVersionMismatch
    case protocolFeaturesMismatch
    case hostBusy
    case hostUpdateInProgress
    case rejected
    case unauthorized
    case takeoverRequiresTrustedRequester
}

package struct MirageSessionBootstrapRequest: Codable, Sendable {
    package let protocolVersion: Int
    package let requestedFeatures: MirageFeatureSet
    package let clientRequiresMediaEncryption: Bool
    package let requestHostUpdateOnProtocolMismatch: Bool?
    package let requestTakeoverIfBusy: Bool?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestedFeatures
        case clientRequiresMediaEncryption
        case requestHostUpdateOnProtocolMismatch
        case requestTakeoverIfBusy
    }

    package init(
        protocolVersion: Int,
        requestedFeatures: MirageFeatureSet,
        clientRequiresMediaEncryption: Bool,
        requestHostUpdateOnProtocolMismatch: Bool? = nil,
        requestTakeoverIfBusy: Bool? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestedFeatures = requestedFeatures
        self.clientRequiresMediaEncryption = clientRequiresMediaEncryption
        self.requestHostUpdateOnProtocolMismatch = requestHostUpdateOnProtocolMismatch
        self.requestTakeoverIfBusy = requestTakeoverIfBusy
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        requestedFeatures = try container.decode(MirageFeatureSet.self, forKey: .requestedFeatures)
        clientRequiresMediaEncryption = try container.decodeIfPresent(
            Bool.self,
            forKey: .clientRequiresMediaEncryption
        ) ?? false
        requestHostUpdateOnProtocolMismatch = try container.decodeIfPresent(
            Bool.self,
            forKey: .requestHostUpdateOnProtocolMismatch
        )
        requestTakeoverIfBusy = try container.decodeIfPresent(
            Bool.self,
            forKey: .requestTakeoverIfBusy
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(requestedFeatures, forKey: .requestedFeatures)
        try container.encode(clientRequiresMediaEncryption, forKey: .clientRequiresMediaEncryption)
        try container.encodeIfPresent(
            requestHostUpdateOnProtocolMismatch,
            forKey: .requestHostUpdateOnProtocolMismatch
        )
        try container.encodeIfPresent(requestTakeoverIfBusy, forKey: .requestTakeoverIfBusy)
    }
}

package struct MirageSessionBootstrapResponse: Codable, Sendable {
    package let accepted: Bool
    package let hostID: UUID
    package let hostName: String
    package let selectedFeatures: MirageFeatureSet
    /// Whether media payload encryption is required for this session.
    package let mediaEncryptionEnabled: Bool
    /// Auth token required for UDP registration packets.
    package let udpRegistrationToken: Data
    /// True when the host trust provider indicates a one-time auto-trust notice is appropriate.
    package let autoTrustGranted: Bool?
    /// True when the host explicitly allows this client to reuse host-published off-LAN reachability metadata.
    package let remoteAccessAllowed: Bool?
    /// Explicit rejection reason when `accepted` is false.
    package let rejectionReason: MirageSessionBootstrapRejectionReason?
    /// Host protocol version reported when the host rejects bootstrap for a version mismatch.
    package let protocolMismatchHostVersion: Int?
    /// Client protocol version reported when the host rejects bootstrap for a version mismatch.
    package let protocolMismatchClientVersion: Int?
    /// Whether the host accepted a client-requested update install during mismatch handling.
    package let protocolMismatchUpdateTriggerAccepted: Bool?
    /// Human-readable host update trigger status returned during mismatch handling.
    package let protocolMismatchUpdateTriggerMessage: String?

    package init(
        accepted: Bool,
        hostID: UUID,
        hostName: String,
        selectedFeatures: MirageFeatureSet,
        mediaEncryptionEnabled: Bool,
        udpRegistrationToken: Data,
        autoTrustGranted: Bool? = nil,
        remoteAccessAllowed: Bool? = nil,
        rejectionReason: MirageSessionBootstrapRejectionReason? = nil,
        protocolMismatchHostVersion: Int? = nil,
        protocolMismatchClientVersion: Int? = nil,
        protocolMismatchUpdateTriggerAccepted: Bool? = nil,
        protocolMismatchUpdateTriggerMessage: String? = nil
    ) {
        self.accepted = accepted
        self.hostID = hostID
        self.hostName = hostName
        self.selectedFeatures = selectedFeatures
        self.mediaEncryptionEnabled = mediaEncryptionEnabled
        self.udpRegistrationToken = udpRegistrationToken
        self.autoTrustGranted = autoTrustGranted
        self.remoteAccessAllowed = remoteAccessAllowed
        self.rejectionReason = rejectionReason
        self.protocolMismatchHostVersion = protocolMismatchHostVersion
        self.protocolMismatchClientVersion = protocolMismatchClientVersion
        self.protocolMismatchUpdateTriggerAccepted = protocolMismatchUpdateTriggerAccepted
        self.protocolMismatchUpdateTriggerMessage = protocolMismatchUpdateTriggerMessage
    }
}

package struct DisconnectMessage: Codable {
    package let reason: DisconnectReason
    package let message: String?

    package enum DisconnectReason: String, Codable {
        case userRequested
        case timeout
        case error
        case hostShutdown
        case hostUpdateInProgress
        case authFailed
        case takenOver
        case backgroundLeaseExpired
    }

    package init(reason: DisconnectReason, message: String? = nil) {
        self.reason = reason
        self.message = message
    }
}

package struct TransportRefreshRequestMessage: Codable, Sendable {
    package let streamID: StreamID?
    package let reason: String
    package let requestedAtNs: UInt64

    package init(
        streamID: StreamID?,
        reason: String,
        requestedAtNs: UInt64 = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000_000)
    ) {
        self.streamID = streamID
        self.reason = reason
        self.requestedAtNs = requestedAtNs
    }
}

package struct ClientBackgroundLeaseMessage: Codable, Sendable, Equatable {
    package let leaseID: UUID
    package let durationSeconds: TimeInterval
    package let requestedAt: Date

    package init(
        leaseID: UUID = UUID(),
        durationSeconds: TimeInterval,
        requestedAt: Date = Date()
    ) {
        self.leaseID = leaseID
        self.durationSeconds = durationSeconds
        self.requestedAt = requestedAt
    }
}
