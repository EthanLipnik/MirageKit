//
//  MirageKit.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

@_exported import Foundation
@_exported import Loom
@_exported import LoomCloudKit

/// Stable identifier for a host window in Mirage protocol messages.
public typealias WindowID = UInt32

/// Stable identifier for a media stream within a Mirage session.
public typealias StreamID = UInt16

/// Stable identifier for a logical stream session across control messages.
public typealias StreamSessionID = UUID

// MARK: - Version

/// Public entry point for MirageKit-wide constants and shared service configuration.
public enum MirageKit {
    /// MirageKit package version exposed to hosts, clients, and diagnostics.
    public static let version = "1.1.1"

    /// Current Mirage wire protocol version required by both hosts and clients, encoded as YYMMDD.
    public static let protocolVersion: UInt32 = mirageProtocolVersion

    /// Bonjour service type used for peer discovery on the local network.
    public static let serviceType = "_mirage._tcp"

    /// UDP port used for overlay reachability probes.
    public static let overlayProbePort: UInt16 = 9852

    /// Stable user-visible substring emitted when bounded first-frame recovery is exhausted.
    public static let firstFramePresentationFailureTerminalMessage =
        "Stream failed to present its first frame after bounded recovery."

    /// Keychain service name for the user's Loom-backed Mirage identity.
    public static let identityService = "com.mirage.identity.account.v2"

    /// Shared app-group key for the stable Mirage device identifier.
    public static let sharedDeviceIDKey = "com.mirage.shared.deviceID"

    /// App-group suite used by Mirage targets that share the device identifier.
    public static let sharedDeviceIDSuiteName = "group.com.ethanlipnik.Mirage"

    /// Process-wide identity manager configured for Mirage's identity service.
    @MainActor
    public static let identityManager = LoomIdentityManager(
        service: identityService
    )

    /// Builds the CloudKit configuration used by Mirage's peer identity sync.
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

    /// Returns whether a user-visible error or disconnect reason represents terminal first-frame failure.
    public static func isFirstFramePresentationTerminalFailure(_ message: String) -> Bool {
        message.contains(firstFramePresentationFailureTerminalMessage)
    }

    /// Returns Mirage's canonical shared device identifier, creating it when needed.
    /// - Parameter suiteName: App-group suite that stores the identifier. Pass `nil` to use standard defaults.
    public static func getOrCreateSharedDeviceID(suiteName: String? = sharedDeviceIDSuiteName) -> UUID {
        LoomSharedDeviceID.getOrCreate(
            suiteName: suiteName,
            key: sharedDeviceIDKey
        )
    }
}
