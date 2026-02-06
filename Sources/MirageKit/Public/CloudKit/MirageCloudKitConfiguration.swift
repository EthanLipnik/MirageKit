//
//  MirageCloudKitConfiguration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Configuration for CloudKit-based trust and sharing.
//

import Foundation

/// Configuration for MirageKit CloudKit integration.
///
/// Use this to customize CloudKit behavior for your app. The defaults use
/// "Mirage" prefixed names for record types and zones.
///
/// ## CloudKit Setup
///
/// Before using CloudKit features, configure your app in the Apple Developer portal:
///
/// 1. Go to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
/// 2. Select your app identifier and enable iCloud with CloudKit
/// 3. Go to [CloudKit Console](https://icloud.developer.apple.com/)
/// 4. Select your container and create the required record types:
///
/// **MirageDevice** (or your custom `deviceRecordType`):
/// - `name` (String) - Device display name
/// - `deviceType` (String) - Device type (mac, iPad, iPhone, vision)
/// - `lastSeen` (Date/Time) - Last activity timestamp
///
/// **MirageHost** (or your custom `hostRecordType`):
/// - `name` (String) - Host display name
/// - `createdAt` (Date/Time) - Creation timestamp
///
/// 5. Add indexes for queryable fields (name, deviceType)
/// 6. Deploy schema changes to production
///
public struct MirageCloudKitConfiguration: Sendable {
    /// CloudKit container identifier (e.g., "iCloud.com.yourcompany.YourApp").
    public let containerIdentifier: String

    /// Record type for device registration.
    public let deviceRecordType: String

    /// Record type for host records used in sharing.
    public let hostRecordType: String

    /// Zone name for host records.
    public let hostZoneName: String

    /// Title shown in the CloudKit sharing UI.
    public let shareTitle: String

    /// UserDefaults key for storing the stable device ID.
    public let deviceIDKey: String

    /// Cache TTL for share participants in seconds.
    public let shareParticipantCacheTTL: TimeInterval

    /// Creates a CloudKit configuration with the specified settings.
    ///
    /// - Parameters:
    ///   - containerIdentifier: CloudKit container identifier (required).
    ///   - deviceRecordType: Record type for devices. Defaults to "MirageDevice".
    ///   - hostRecordType: Record type for hosts. Defaults to "MirageHost".
    ///   - hostZoneName: Zone name for host records. Defaults to "MirageHostZone".
    ///   - shareTitle: Title for sharing UI. Defaults to "Host Access".
    ///   - deviceIDKey: UserDefaults key for device ID. Defaults to "com.mirage.cloudkit.deviceID".
    ///   - shareParticipantCacheTTL: Cache TTL in seconds. Defaults to 300 (5 minutes).
    public init(
        containerIdentifier: String,
        deviceRecordType: String = "MirageDevice",
        hostRecordType: String = "MirageHost",
        hostZoneName: String = "MirageHostZone",
        shareTitle: String = "Host Access",
        deviceIDKey: String = "com.mirage.cloudkit.deviceID",
        shareParticipantCacheTTL: TimeInterval = 300
    ) {
        self.containerIdentifier = containerIdentifier
        self.deviceRecordType = deviceRecordType
        self.hostRecordType = hostRecordType
        self.hostZoneName = hostZoneName
        self.shareTitle = shareTitle
        self.deviceIDKey = deviceIDKey
        self.shareParticipantCacheTTL = shareParticipantCacheTTL
    }
}
