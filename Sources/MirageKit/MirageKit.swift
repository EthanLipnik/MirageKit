//
//  MirageKit.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import Foundation
import Loom
import LoomCloudKit

// MARK: - Version

/// Public entry point for MirageKit-wide constants and shared service configuration.
public enum MirageKit {
    /// MirageKit package version exposed to hosts, clients, and diagnostics.
    public static let version = "1.1.6"

    /// Current Mirage discovery compatibility version advertised through peer metadata.
    public static let discoveryProtocolVersion: UInt32 = MirageWireProtocol.currentDiscoveryVersion

    /// Current Mirage control protocol version required by both hosts and clients, encoded as YYMMDD.
    public static let controlProtocolVersion: UInt32 = MirageWireProtocol.currentControlVersion

    /// Current Mirage media packet version used by fixed-layout video and audio packet headers.
    public static let mediaPacketProtocolVersion: UInt32 = MirageWireProtocol.currentMediaPacketVersion

    /// Bonjour service type used for peer discovery on the local network.
    public static let serviceType = MirageNetworkDefaults.serviceType

    /// TCP port used for overlay reachability probes.
    public static let overlayProbePort = MirageNetworkDefaults.overlayProbePort

    /// Preferred TCP listener port used for direct Mirage sessions.
    public static let directTCPPort = MirageNetworkDefaults.directTCPPort

    /// Preferred UDP listener port used for direct Mirage sessions.
    public static let directUDPPort = MirageNetworkDefaults.directUDPPort

    /// Preferred QUIC listener port used for direct Mirage sessions.
    public static let directQUICPort = MirageNetworkDefaults.directQUICPort

    /// Keychain service name for the user's Loom-backed Mirage identity.
    public static let identityService = MirageIdentityConfiguration.identityService

    /// Shared app-group key for the stable Mirage device identifier.
    public static let sharedDeviceIDKey = MirageIdentityConfiguration.sharedDeviceIDKey

    /// App-group suite used by Mirage targets that share the device identifier.
    public static let sharedDeviceIDSuiteName = MirageIdentityConfiguration.sharedDeviceIDSuiteName

    /// Shared-device identifier storage configuration for Mirage apps.
    public static let sharedDeviceIDConfiguration = MirageIdentityConfiguration.sharedDeviceIDConfiguration

    /// Process-wide identity manager configured for Mirage's identity service.
    @MainActor
    public static let identityManager = LoomIdentityManager(
        service: identityService
    )

    /// Builds the Mirage-owned CloudKit identity configuration used by peer identity sync.
    public static func makeMirageCloudKitIdentityConfiguration(
        containerIdentifier: String
    ) -> MirageCloudKitIdentityConfiguration {
        MirageIdentityConfiguration.cloudKitIdentityConfiguration(
            containerIdentifier: containerIdentifier
        )
    }

    /// Builds the CloudKit configuration used by Mirage's peer identity sync.
    public static func makeCloudKitConfiguration(containerIdentifier: String) -> LoomCloudKitConfiguration {
        makeMirageCloudKitIdentityConfiguration(
            containerIdentifier: containerIdentifier
        ).loomCloudKitConfiguration
    }

    /// Returns Mirage's canonical shared device identifier, creating it when needed.
    /// - Parameter suiteName: App-group suite that stores the identifier. Pass `nil` to use standard defaults.
    public static func getOrCreateSharedDeviceID(suiteName: String? = sharedDeviceIDSuiteName) -> UUID {
        LoomSharedDeviceID.getOrCreate(
            suiteName: suiteName,
            key: sharedDeviceIDKey
        )
    }

    /// Returns Mirage's canonical shared device identifier for the supplied storage configuration.
    public static func getOrCreateSharedDeviceID(configuration: MirageSharedDeviceIDConfiguration) -> UUID {
        LoomSharedDeviceID.getOrCreate(
            suiteName: configuration.suiteName,
            key: configuration.key
        )
    }
}

private extension MirageCloudKitIdentityConfiguration {
    var loomCloudKitConfiguration: LoomCloudKitConfiguration {
        LoomCloudKitConfiguration(
            containerIdentifier: containerIdentifier,
            deviceRecordType: deviceRecordType,
            peerRecordType: peerRecordType,
            peerZoneName: peerZoneName,
            participantIdentityRecordType: participantIdentityRecordType,
            deviceIDKey: sharedDeviceIDConfiguration.key,
            deviceIDSuiteName: sharedDeviceIDConfiguration.suiteName
        )
    }
}
