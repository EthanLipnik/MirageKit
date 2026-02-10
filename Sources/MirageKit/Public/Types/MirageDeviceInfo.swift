//
//  MirageDeviceInfo.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation

/// Information about a connecting device, used for approval flow
public struct MirageDeviceInfo: Identifiable, Sendable {
    /// Unique identifier for this connection attempt
    public let id: UUID

    /// Name of the device (if known)
    public let name: String

    /// Type of device
    public let deviceType: DeviceType

    /// Network endpoint description (IP address/hostname)
    public let endpoint: String

    /// iCloud user record ID for trust evaluation, if available.
    public let iCloudUserID: String?

    /// Identity key identifier from signed handshake payload.
    public let identityKeyID: String?

    /// Identity public key from signed handshake payload.
    public let identityPublicKey: Data?

    /// Whether the handshake identity signature was validated.
    public let isIdentityAuthenticated: Bool
    public init(
        id: UUID = UUID(),
        name: String,
        deviceType: DeviceType,
        endpoint: String,
        iCloudUserID: String? = nil,
        identityKeyID: String? = nil,
        identityPublicKey: Data? = nil,
        isIdentityAuthenticated: Bool = false
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.endpoint = endpoint
        self.iCloudUserID = iCloudUserID
        self.identityKeyID = identityKeyID
        self.identityPublicKey = identityPublicKey
        self.isIdentityAuthenticated = isIdentityAuthenticated
    }
}
