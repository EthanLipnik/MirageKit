//
//  MirageCloudKitHostInfo.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Host information retrieved from CloudKit.
//

import Foundation

/// Represents a host stored in CloudKit.
///
/// Hosts are stored when the Mirage Host app registers itself with iCloud.
/// Clients can fetch these records to see hosts even when they're offline.
///
/// Hosts may be:
/// - **Own hosts**: Devices belonging to the same iCloud account
/// - **Shared hosts**: Devices shared by friends via CKShare
public struct MirageCloudKitHostInfo: Identifiable, Hashable, Sendable {
    /// Unique device identifier (stable across sessions).
    public let id: UUID

    /// Display name of the host.
    public let name: String

    /// Type of device (always .mac for hosts).
    public let deviceType: DeviceType

    /// Host capabilities (HEVC support, frame rate, etc.).
    public let capabilities: MirageHostCapabilities

    /// When the host last updated its CloudKit record.
    public let lastSeen: Date

    /// CloudKit user record ID of the host owner.
    ///
    /// Nil for own hosts (same account), present for shared hosts.
    public let ownerUserID: String?

    /// Whether this host was obtained from a CKShare (friend's host).
    public let isShared: Bool

    /// CloudKit record ID for reference.
    public let recordID: String

    /// Creates a CloudKit host info instance.
    ///
    /// - Parameters:
    ///   - id: Device identifier.
    ///   - name: Host display name.
    ///   - deviceType: Device type.
    ///   - capabilities: Host capabilities.
    ///   - lastSeen: Last seen timestamp.
    ///   - ownerUserID: Owner's CloudKit user ID (nil for own hosts).
    ///   - isShared: Whether from a CKShare.
    ///   - recordID: CloudKit record ID.
    public init(
        id: UUID,
        name: String,
        deviceType: DeviceType,
        capabilities: MirageHostCapabilities,
        lastSeen: Date,
        ownerUserID: String?,
        isShared: Bool,
        recordID: String
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.capabilities = capabilities
        self.lastSeen = lastSeen
        self.ownerUserID = ownerUserID
        self.isShared = isShared
        self.recordID = recordID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: MirageCloudKitHostInfo, rhs: MirageCloudKitHostInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - CloudKit Record Keys

public extension MirageCloudKitHostInfo {
    /// Keys used for CloudKit record fields.
    enum RecordKey: String {
        case deviceID
        case name
        case deviceType
        case maxFrameRate
        case supportsHEVC
        case supportsP3
        case maxStreams
        case protocolVersion
        case lastSeen
        case createdAt
    }
}
