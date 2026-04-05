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
    case rejected
    case unauthorized
}

package struct MirageSessionBootstrapRequest: Codable, Sendable {
    package let protocolVersion: Int
    package let requestedFeatures: MirageFeatureSet
    package let requestHostUpdateOnProtocolMismatch: Bool?

    package init(
        protocolVersion: Int,
        requestedFeatures: MirageFeatureSet,
        requestHostUpdateOnProtocolMismatch: Bool? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestedFeatures = requestedFeatures
        self.requestHostUpdateOnProtocolMismatch = requestHostUpdateOnProtocolMismatch
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
    /// Optional metadata for protocol mismatch handling.
    package let protocolMismatchHostVersion: Int?
    package let protocolMismatchClientVersion: Int?
    /// Optional result when a client requested host update on protocol mismatch.
    package let protocolMismatchUpdateTriggerAccepted: Bool?
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
        case authFailed
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
