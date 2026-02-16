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

package enum HelloRejectionReason: String, Codable, Sendable {
    case protocolVersionMismatch
    case protocolFeaturesMismatch
    case hostBusy
    case rejected
    case unauthorized
}

package struct MirageIdentityEnvelope: Codable, Sendable {
    package let keyID: String
    package let publicKey: Data
    package let timestampMs: Int64
    package let nonce: String
    package let signature: Data

    package init(
        keyID: String,
        publicKey: Data,
        timestampMs: Int64,
        nonce: String,
        signature: Data
    ) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.timestampMs = timestampMs
        self.nonce = nonce
        self.signature = signature
    }
}

package struct HelloMessage: Codable {
    package let deviceID: UUID
    package let deviceName: String
    package let deviceType: DeviceType
    package let protocolVersion: Int
    package let capabilities: MirageHostCapabilities
    package let negotiation: MirageProtocolNegotiation
    /// iCloud user record ID for trust evaluation, if available.
    package let iCloudUserID: String?
    /// Signed identity envelope proving possession of the account private key.
    package let identity: MirageIdentityEnvelope
    /// Optional one-shot signal asking the host to trigger a software update when protocol mismatch is detected.
    package let requestHostUpdateOnProtocolMismatch: Bool?

    package init(
        deviceID: UUID,
        deviceName: String,
        deviceType: DeviceType,
        protocolVersion: Int,
        capabilities: MirageHostCapabilities,
        negotiation: MirageProtocolNegotiation,
        iCloudUserID: String? = nil,
        identity: MirageIdentityEnvelope,
        requestHostUpdateOnProtocolMismatch: Bool? = nil
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.negotiation = negotiation
        self.iCloudUserID = iCloudUserID
        self.identity = identity
        self.requestHostUpdateOnProtocolMismatch = requestHostUpdateOnProtocolMismatch
    }
}

package struct HelloResponseMessage: Codable {
    package let accepted: Bool
    package let hostID: UUID
    package let hostName: String
    package let requiresAuth: Bool
    package let dataPort: UInt16
    package let negotiation: MirageProtocolNegotiation
    /// Echoed client hello nonce for request/response binding.
    package let requestNonce: String
    /// Whether media payload encryption is required for this session.
    package let mediaEncryptionEnabled: Bool
    /// Auth token required for UDP registration packets.
    package let udpRegistrationToken: Data
    /// True when the host trust provider indicates a one-time auto-trust notice is appropriate.
    package let autoTrustGranted: Bool?
    /// Signed host identity envelope.
    package let identity: MirageIdentityEnvelope
    /// Explicit rejection reason when `accepted` is false.
    package let rejectionReason: HelloRejectionReason?
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
        requiresAuth: Bool,
        dataPort: UInt16,
        negotiation: MirageProtocolNegotiation,
        requestNonce: String,
        mediaEncryptionEnabled: Bool,
        udpRegistrationToken: Data,
        autoTrustGranted: Bool? = nil,
        identity: MirageIdentityEnvelope,
        rejectionReason: HelloRejectionReason? = nil,
        protocolMismatchHostVersion: Int? = nil,
        protocolMismatchClientVersion: Int? = nil,
        protocolMismatchUpdateTriggerAccepted: Bool? = nil,
        protocolMismatchUpdateTriggerMessage: String? = nil
    ) {
        self.accepted = accepted
        self.hostID = hostID
        self.hostName = hostName
        self.requiresAuth = requiresAuth
        self.dataPort = dataPort
        self.negotiation = negotiation
        self.requestNonce = requestNonce
        self.mediaEncryptionEnabled = mediaEncryptionEnabled
        self.udpRegistrationToken = udpRegistrationToken
        self.autoTrustGranted = autoTrustGranted
        self.identity = identity
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
