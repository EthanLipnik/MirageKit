//
//  MirageHostBootstrapConfiguration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  Shared host wake/unlock bootstrap configuration.
//

import Foundation
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
    public var sshHostKeyFingerprint: String
    public var controlAuthSecret: String
    public var autoEndpoints: [LoomBootstrapEndpoint]
    public var wakeOnLANMACAddress: String
    public var wakeOnLANBroadcasts: [String]
    public var remoteLoginReachable: Bool
    public var preloginDaemonReady: Bool

    public init(
        enabled: Bool = false,
        userEndpointHost: String = "",
        userEndpointPort: Int = 22,
        sshPort: Int = 22,
        controlPort: Int = 9851,
        sshHostKeyFingerprint: String = "",
        controlAuthSecret: String = Self.makeDefaultControlAuthSecret(),
        autoEndpoints: [LoomBootstrapEndpoint] = [],
        wakeOnLANMACAddress: String = "",
        wakeOnLANBroadcasts: [String] = [],
        remoteLoginReachable: Bool = false,
        preloginDaemonReady: Bool = false
    ) {
        self.enabled = enabled
        self.userEndpointHost = userEndpointHost
        self.userEndpointPort = userEndpointPort
        self.sshPort = sshPort
        self.controlPort = controlPort
        self.sshHostKeyFingerprint = sshHostKeyFingerprint
        self.controlAuthSecret = controlAuthSecret
        self.autoEndpoints = autoEndpoints
        self.wakeOnLANMACAddress = wakeOnLANMACAddress
        self.wakeOnLANBroadcasts = wakeOnLANBroadcasts
        self.remoteLoginReachable = remoteLoginReachable
        self.preloginDaemonReady = preloginDaemonReady
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case userEndpointHost
        case userEndpointPort
        case sshPort
        case controlPort
        case sshHostKeyFingerprint
        case controlAuthSecret
        case autoEndpoints
        case wakeOnLANMACAddress
        case wakeOnLANBroadcasts
        case remoteLoginReachable
        case preloginDaemonReady
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        userEndpointHost = try container.decodeIfPresent(String.self, forKey: .userEndpointHost) ?? ""
        userEndpointPort = try container.decodeIfPresent(Int.self, forKey: .userEndpointPort) ?? 22
        sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        controlPort = try container.decodeIfPresent(Int.self, forKey: .controlPort) ?? 9851
        sshHostKeyFingerprint = try container.decodeIfPresent(String.self, forKey: .sshHostKeyFingerprint) ?? ""
        controlAuthSecret = try container.decodeIfPresent(String.self, forKey: .controlAuthSecret) ??
            Self.makeDefaultControlAuthSecret()
        autoEndpoints = try container.decodeIfPresent([LoomBootstrapEndpoint].self, forKey: .autoEndpoints) ?? []
        wakeOnLANMACAddress = try container.decodeIfPresent(String.self, forKey: .wakeOnLANMACAddress) ?? ""
        wakeOnLANBroadcasts = try container.decodeIfPresent([String].self, forKey: .wakeOnLANBroadcasts) ?? []
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
            let mac = wakeOnLANMACAddress.trimmingCharacters(in: .whitespacesAndNewlines)
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

        let fingerprint = sshHostKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let controlSecret = controlAuthSecret
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let payload = BootstrapMetadataPayload(
            version: 2,
            enabled: enabled,
            supportsPreloginDaemon: preloginDaemonReady,
            supportsControlChannel: preloginDaemonReady,
            supportsCredentialSubmission: remoteLoginReachable,
            endpoints: endpoints,
            sshPort: UInt16(clamping: sshPort),
            controlPort: UInt16(clamping: controlPort),
            sshHostKeyFingerprint: fingerprint.isEmpty ? nil : fingerprint,
            controlAuthSecret: controlSecret.isEmpty ? nil : controlSecret,
            wakeOnLAN: wakeInfo
        )

        guard let encoded = try? JSONEncoder().encode(payload) else {
            return nil
        }
        return try? JSONDecoder().decode(LoomBootstrapMetadata.self, from: encoded)
    }

    public static func makeDefaultControlAuthSecret() -> String {
        let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }
}

private struct BootstrapMetadataPayload: Codable {
    let version: Int
    let enabled: Bool
    let supportsPreloginDaemon: Bool
    let supportsControlChannel: Bool
    let supportsCredentialSubmission: Bool
    let endpoints: [LoomBootstrapEndpoint]
    let sshPort: UInt16?
    let controlPort: UInt16?
    let sshHostKeyFingerprint: String?
    let controlAuthSecret: String?
    let wakeOnLAN: LoomWakeOnLANInfo?
}

private extension UInt16 {
    init?(clamping value: Int) {
        guard value > 0, value <= Int(UInt16.max) else { return nil }
        self = UInt16(value)
    }
}

#endif
