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

struct HelloMessage: Codable {
    let deviceID: UUID
    let deviceName: String
    let deviceType: DeviceType
    let protocolVersion: Int
    let capabilities: MirageHostCapabilities
    /// iCloud user record ID for trust evaluation, if available.
    let iCloudUserID: String?

    init(
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

struct HelloResponseMessage: Codable {
    let accepted: Bool
    let hostID: UUID
    let hostName: String
    let requiresAuth: Bool
    let dataPort: UInt16
    let audioPort: UInt16?
}

struct DisconnectMessage: Codable {
    let reason: DisconnectReason
    let message: String?

    enum DisconnectReason: String, Codable {
        case userRequested
        case timeout
        case error
        case hostShutdown
        case authFailed
    }
}
