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

    /// MirageKit default Bonjour service type used for peer discovery on the local network.
    public static let serviceType = "_miragekit._tcp"

    /// MirageKit default bootstrap control port.
    public static let bootstrapControlPort: Int = 38551

    /// MirageKit default TCP port used for overlay reachability probes.
    public static let overlayProbePort: UInt16 = 38552

    /// MirageKit default TCP listener port used for direct sessions.
    public static let directTCPPort: UInt16 = 38553

    /// MirageKit default UDP listener port used for direct sessions.
    public static let directUDPPort: UInt16 = 38554

    /// MirageKit QUIC port constant kept for packages that still reference the public API.
    public static let directQUICPort: UInt16 = 38555

    /// Bonjour service type used by the Mirage app for production peer discovery.
    public static let mirageAppServiceType = MirageNetworkDefaults.serviceType

    /// Bootstrap control port used by the Mirage app.
    public static let mirageAppBootstrapControlPort: Int = 9851

    /// Overlay probe port used by the Mirage app.
    public static let mirageAppOverlayProbePort = MirageNetworkDefaults.overlayProbePort

    /// Direct TCP listener port used by the Mirage app.
    public static let mirageAppDirectTCPPort = MirageNetworkDefaults.directTCPPort

    /// Direct UDP listener port used by the Mirage app.
    public static let mirageAppDirectUDPPort = MirageNetworkDefaults.directUDPPort

    /// Mirage app QUIC port constant kept for packages that still reference the public API.
    public static let mirageAppDirectQUICPort = MirageNetworkDefaults.directQUICPort

    /// Direct transports enabled by the Mirage app.
    public static let mirageAppDirectTransports: Set<LoomTransportKind> = [.tcp, .udp]

    /// Preferred direct transport order used by the Mirage app.
    public static let mirageAppPreferredDirectTransportOrder: [LoomTransportKind] = [.udp, .tcp]

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
