//
//  MirageHostBootstrapConfiguration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//
//  Shared bootstrap configuration for host wake, unlock, and daemon handoff.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)

public struct MirageHostBootstrapConfiguration: Codable, Equatable, Sendable {
    /// Defaults key used for serialized bootstrap configuration.
    public static let defaultsKey = "com.mirage.host.bootstrapConfiguration.v1"

    public var enabled: Bool
    public var userEndpointHost: String
    public var userEndpointPort: Int
    public var sshPort: Int
    public var controlPort: Int
    public var controlAuthSecret: String
    public var autoEndpoints: [LoomBootstrapEndpoint]
    public var sshHostKeyFingerprints: [String]
    public var manualWakeOnLANMACAddress: String
    public var wakeOnLANMACAddress: String
    public var wakeOnLANBroadcasts: [String]
    public var wakeOnLANInterfaceName: String
    public var wakeOnLANInterfaceDisplayName: String
    public var wakeOnLANUsesWiFi: Bool
    public var wakeOnLANWiFiPrivateAddressWarning: Bool
    public var remoteLoginReachable: Bool
    public var preloginDaemonReady: Bool

    public init(
        enabled: Bool = false,
        userEndpointHost: String = "",
        userEndpointPort: Int = 22,
        sshPort: Int = 22,
        controlPort: Int = MirageKit.bootstrapControlPort,
        controlAuthSecret: String = Self.makeDefaultControlAuthSecret(),
        autoEndpoints: [LoomBootstrapEndpoint] = [],
        sshHostKeyFingerprints: [String] = [],
        manualWakeOnLANMACAddress: String = "",
        wakeOnLANMACAddress: String = "",
        wakeOnLANBroadcasts: [String] = [],
        wakeOnLANInterfaceName: String = "",
        wakeOnLANInterfaceDisplayName: String = "",
        wakeOnLANUsesWiFi: Bool = false,
        wakeOnLANWiFiPrivateAddressWarning: Bool = false,
        remoteLoginReachable: Bool = false,
        preloginDaemonReady: Bool = false
    ) {
        self.enabled = enabled
        self.userEndpointHost = userEndpointHost
        self.userEndpointPort = userEndpointPort
        self.sshPort = sshPort
        self.controlPort = controlPort
        self.controlAuthSecret = controlAuthSecret
        self.autoEndpoints = autoEndpoints
        self.sshHostKeyFingerprints = sshHostKeyFingerprints
        self.manualWakeOnLANMACAddress = manualWakeOnLANMACAddress
        self.wakeOnLANMACAddress = wakeOnLANMACAddress
        self.wakeOnLANBroadcasts = wakeOnLANBroadcasts
        self.wakeOnLANInterfaceName = wakeOnLANInterfaceName
        self.wakeOnLANInterfaceDisplayName = wakeOnLANInterfaceDisplayName
        self.wakeOnLANUsesWiFi = wakeOnLANUsesWiFi
        self.wakeOnLANWiFiPrivateAddressWarning = wakeOnLANWiFiPrivateAddressWarning
        self.remoteLoginReachable = remoteLoginReachable
        self.preloginDaemonReady = preloginDaemonReady
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case userEndpointHost
        case userEndpointPort
        case sshPort
        case controlPort
        case controlAuthSecret
        case autoEndpoints
        case sshHostKeyFingerprints
        case manualWakeOnLANMACAddress
        case wakeOnLANMACAddress
        case wakeOnLANBroadcasts
        case wakeOnLANInterfaceName
        case wakeOnLANInterfaceDisplayName
        case wakeOnLANUsesWiFi
        case wakeOnLANWiFiPrivateAddressWarning
        case remoteLoginReachable
        case preloginDaemonReady
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        userEndpointHost = try container.decodeIfPresent(String.self, forKey: .userEndpointHost) ?? ""
        userEndpointPort = try container.decodeIfPresent(Int.self, forKey: .userEndpointPort) ?? 22
        sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        controlPort = try container.decodeIfPresent(Int.self, forKey: .controlPort) ??
            MirageKit.mirageAppBootstrapControlPort
        controlAuthSecret = try container.decodeIfPresent(String.self, forKey: .controlAuthSecret) ??
            Self.makeDefaultControlAuthSecret()
        autoEndpoints = try container.decodeIfPresent([LoomBootstrapEndpoint].self, forKey: .autoEndpoints) ?? []
        sshHostKeyFingerprints = try container.decodeIfPresent(
            [String].self,
            forKey: .sshHostKeyFingerprints
        ) ?? []
        manualWakeOnLANMACAddress = try container.decodeIfPresent(
            String.self,
            forKey: .manualWakeOnLANMACAddress
        ) ?? ""
        wakeOnLANMACAddress = try container.decodeIfPresent(String.self, forKey: .wakeOnLANMACAddress) ?? ""
        wakeOnLANBroadcasts = try container.decodeIfPresent([String].self, forKey: .wakeOnLANBroadcasts) ?? []
        wakeOnLANInterfaceName = try container.decodeIfPresent(String.self, forKey: .wakeOnLANInterfaceName) ?? ""
        wakeOnLANInterfaceDisplayName = try container.decodeIfPresent(
            String.self,
            forKey: .wakeOnLANInterfaceDisplayName
        ) ?? ""
        wakeOnLANUsesWiFi = try container.decodeIfPresent(Bool.self, forKey: .wakeOnLANUsesWiFi) ?? false
        wakeOnLANWiFiPrivateAddressWarning = try container.decodeIfPresent(
            Bool.self,
            forKey: .wakeOnLANWiFiPrivateAddressWarning
        ) ?? false
        remoteLoginReachable = try container.decodeIfPresent(Bool.self, forKey: .remoteLoginReachable) ?? false
        preloginDaemonReady = try container.decodeIfPresent(Bool.self, forKey: .preloginDaemonReady) ?? false
    }

    public func toBootstrapMetadata() -> LoomBootstrapMetadata? {
        var endpoints = autoEndpoints
        let trimmedHost = userEndpointHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHost.isEmpty,
           let userPort = UInt16(clamping: userEndpointPort) {
            endpoints.insert(
                LoomBootstrapEndpoint(
                    host: trimmedHost,
                    port: userPort,
                    source: .user
                ),
                at: 0
            )
        }

        let wakeInfo: LoomWakeOnLANInfo? = {
            let manualMAC = manualWakeOnLANMACAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let autoMAC = wakeOnLANMACAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let mac = MirageBootstrapNetworkDetector.isValidWakeMACAddress(manualMAC) ? manualMAC : autoMAC
            guard !mac.isEmpty else { return nil }
            let broadcasts = wakeOnLANBroadcasts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !broadcasts.isEmpty else { return nil }
            return LoomWakeOnLANInfo(
                macAddress: mac,
                broadcastAddresses: broadcasts
            )
        }()

        let trimmedControlAuthSecret = controlAuthSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        return LoomBootstrapMetadata(
            enabled: enabled,
            supportsPreloginDaemon: preloginDaemonReady,
            endpoints: endpoints,
            sshPort: UInt16(clamping: sshPort),
            controlPort: UInt16(clamping: controlPort),
            controlAuthSecret: preloginDaemonReady && !trimmedControlAuthSecret.isEmpty ?
                trimmedControlAuthSecret :
                nil,
            controlCapabilities: preloginDaemonReady && !trimmedControlAuthSecret.isEmpty ?
                [.commands] :
                [],
            sshHostKeyFingerprints: sshHostKeyFingerprints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            wakeOnLAN: wakeInfo
        )
    }

    public static func makeDefaultControlAuthSecret() -> String {
        let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }
}

private extension UInt16 {
    init?(clamping value: Int) {
        guard value > 0, value <= Int(UInt16.max) else { return nil }
        self = UInt16(value)
    }
}

#endif
