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
    public static let version = "1.0.0"
    public static let protocolVersion: UInt8 = Loom.protocolVersion
    public static let serviceType = "_mirage._tcp"
    public static let relayHeaderPrefix = "x-mirage"
    public static let sharedDeviceIDKey = "com.mirage.shared.deviceID"
    public static let sharedDeviceIDLegacyKeys = [
        "com.mirage.client.deviceID",
        "com.mirage.cloudkit.deviceID",
        LoomSharedDeviceID.key,
    ]

    public static func makeCloudKitConfiguration(containerIdentifier: String) -> LoomCloudKitConfiguration {
        LoomCloudKitConfiguration(
            containerIdentifier: containerIdentifier,
            deviceRecordType: "MirageDevice",
            peerRecordType: "MiragePeer",
            peerZoneName: "MiragePeerZone",
            participantIdentityRecordType: "MirageParticipantIdentity",
            shareTitle: "Mirage Access",
            deviceIDKey: "com.mirage.cloudkit.deviceID"
        )
    }
}
