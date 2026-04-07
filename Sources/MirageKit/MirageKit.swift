//
//  MirageKit.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

@_exported import Foundation
@_exported import Loom
@_exported import LoomCloudKit

// Re-export all public types
public typealias WindowID = UInt32
public typealias StreamID = UInt16
public typealias StreamSessionID = UUID

// MARK: - Version

public enum MirageKit {
    public static let version = "0.15.6"
    public static let protocolVersion: UInt8 = mirageProtocolVersion
    public static let serviceType = "_mirage._tcp"
    public static let relayHeaderPrefix = "x-mirage"
    public static let identityService = "com.mirage.identity.account.v2"
    public static let sharedDeviceIDKey = "com.mirage.shared.deviceID"
    public static let sharedDeviceIDSuiteName = "group.com.ethanlipnik.Mirage"
    @MainActor
    public static let identityManager = LoomIdentityManager(
        service: identityService
    )

    public static func makeCloudKitConfiguration(containerIdentifier: String) -> LoomCloudKitConfiguration {
        LoomCloudKitConfiguration(
            containerIdentifier: containerIdentifier,
            deviceRecordType: "MirageDevice",
            peerRecordType: "MiragePeer",
            peerZoneName: "MiragePeerZone",
            participantIdentityRecordType: "MirageParticipantIdentity",
            deviceIDKey: sharedDeviceIDKey,
            deviceIDSuiteName: sharedDeviceIDSuiteName
        )
    }

    /// Returns Mirage's canonical shared device identifier.
    public static func getOrCreateSharedDeviceID(suiteName: String? = sharedDeviceIDSuiteName) -> UUID {
        LoomSharedDeviceID.getOrCreate(
            suiteName: suiteName,
            key: sharedDeviceIDKey
        )
    }
}
