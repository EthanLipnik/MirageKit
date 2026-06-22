//
//  MirageIdentityConfiguration.swift
//  MirageIdentity
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Shared-device identifier storage configuration.
public struct MirageSharedDeviceIDConfiguration: Sendable, Codable, Equatable {
    /// Defaults key used to persist the stable device identifier.
    public let key: String

    /// App-group suite used to share the device identifier across Mirage targets.
    public let suiteName: String?

    /// Creates a shared-device identifier storage configuration.
    public init(key: String, suiteName: String?) {
        self.key = key
        self.suiteName = suiteName
    }
}

/// CloudKit schema configuration for Mirage peer identity sync.
public struct MirageCloudKitIdentityConfiguration: Sendable, Codable, Equatable {
    /// CloudKit container identifier.
    public let containerIdentifier: String

    /// CloudKit record type used for synced Mirage devices.
    public let deviceRecordType: String

    /// CloudKit record type used for synced Mirage peers.
    public let peerRecordType: String

    /// CloudKit zone used for Mirage peer identity sync.
    public let peerZoneName: String

    /// CloudKit record type used for participant identity keys.
    public let participantIdentityRecordType: String

    /// Shared-device identifier configuration paired with this CloudKit schema.
    public let sharedDeviceIDConfiguration: MirageSharedDeviceIDConfiguration

    /// Creates a CloudKit identity schema configuration.
    public init(
        containerIdentifier: String,
        deviceRecordType: String,
        peerRecordType: String,
        peerZoneName: String,
        participantIdentityRecordType: String,
        sharedDeviceIDConfiguration: MirageSharedDeviceIDConfiguration
    ) {
        self.containerIdentifier = containerIdentifier
        self.deviceRecordType = deviceRecordType
        self.peerRecordType = peerRecordType
        self.peerZoneName = peerZoneName
        self.participantIdentityRecordType = participantIdentityRecordType
        self.sharedDeviceIDConfiguration = sharedDeviceIDConfiguration
    }
}

/// Stable identity configuration names shared by Mirage targets.
public enum MirageIdentityConfiguration {
    /// Keychain service name for the user's Loom-backed Mirage identity.
    public static let identityService = "com.mirage.identity.account.v2"

    /// Shared app-group key for the stable Mirage device identifier.
    public static let sharedDeviceIDKey = "com.mirage.shared.deviceID"

    /// App-group suite used by Mirage targets that share the device identifier.
    public static let sharedDeviceIDSuiteName = "group.com.ethanlipnik.Mirage"

    /// CloudKit record type used for synced Mirage devices.
    public static let cloudKitDeviceRecordType = "MirageDevice"

    /// CloudKit record type used for synced Mirage peers.
    public static let cloudKitPeerRecordType = "MiragePeer"

    /// CloudKit zone used for Mirage peer identity sync.
    public static let cloudKitPeerZoneName = "MiragePeerZone"

    /// CloudKit record type used for participant identity keys.
    public static let cloudKitParticipantIdentityRecordType = "MirageParticipantIdentity"

    /// Default shared-device identifier storage configuration for Mirage apps.
    public static let sharedDeviceIDConfiguration = MirageSharedDeviceIDConfiguration(
        key: sharedDeviceIDKey,
        suiteName: sharedDeviceIDSuiteName
    )

    /// Builds the Mirage-owned CloudKit identity schema configuration.
    public static func cloudKitIdentityConfiguration(
        containerIdentifier: String
    ) -> MirageCloudKitIdentityConfiguration {
        MirageCloudKitIdentityConfiguration(
            containerIdentifier: containerIdentifier,
            deviceRecordType: cloudKitDeviceRecordType,
            peerRecordType: cloudKitPeerRecordType,
            peerZoneName: cloudKitPeerZoneName,
            participantIdentityRecordType: cloudKitParticipantIdentityRecordType,
            sharedDeviceIDConfiguration: sharedDeviceIDConfiguration
        )
    }
}
