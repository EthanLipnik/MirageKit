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

    package init(
        deviceID: UUID,
        deviceName: String,
        deviceType: DeviceType,
        protocolVersion: Int,
        capabilities: MirageHostCapabilities,
        negotiation: MirageProtocolNegotiation,
        iCloudUserID: String? = nil,
        identity: MirageIdentityEnvelope
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.negotiation = negotiation
        self.iCloudUserID = iCloudUserID
        self.identity = identity
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
        identity: MirageIdentityEnvelope
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
