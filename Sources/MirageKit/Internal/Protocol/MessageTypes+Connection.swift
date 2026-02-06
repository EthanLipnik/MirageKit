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

package struct HelloMessage: Codable {
    package let deviceID: UUID
    package let deviceName: String
    package let deviceType: DeviceType
    package let protocolVersion: Int
    package let capabilities: MirageHostCapabilities
    /// iCloud user record ID for trust evaluation, if available.
    package let iCloudUserID: String?

    package init(
        deviceID: UUID,
        deviceName: String,
        deviceType: DeviceType,
        protocolVersion: Int,
        capabilities: MirageHostCapabilities,
        iCloudUserID: String? = nil
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.iCloudUserID = iCloudUserID
    }
}

package struct HelloResponseMessage: Codable {
    package let accepted: Bool
    package let hostID: UUID
    package let hostName: String
    package let requiresAuth: Bool
    package let dataPort: UInt16

    package init(
        accepted: Bool,
        hostID: UUID,
        hostName: String,
        requiresAuth: Bool,
        dataPort: UInt16
    ) {
        self.accepted = accepted
        self.hostID = hostID
        self.hostName = hostName
        self.requiresAuth = requiresAuth
        self.dataPort = dataPort
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
