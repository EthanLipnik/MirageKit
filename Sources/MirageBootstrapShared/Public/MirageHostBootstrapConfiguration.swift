//
//  MirageHostBootstrapConfiguration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Shared host wake/unlock bootstrap configuration.
//

import Foundation

public enum MirageHostBootstrapEndpointSource: String, Codable, CaseIterable, Sendable {
    case user
    case auto
    case lastSeen
}

public struct MirageHostBootstrapEndpoint: Codable, Hashable, Sendable {
    public let host: String
    public let port: UInt16
    public let source: MirageHostBootstrapEndpointSource

    public init(
        host: String,
        port: UInt16,
        source: MirageHostBootstrapEndpointSource
    ) {
        self.host = host
        self.port = port
        self.source = source
    }
}

public struct MirageHostBootstrapConfiguration: Codable, Equatable, Sendable {
    public static let defaultsKey = "com.mirage.host.bootstrapConfiguration.v1"

    public var enabled: Bool
    public var userEndpointHost: String
    public var userEndpointPort: Int
    public var sshPort: Int
    public var controlPort: Int
    public var sshHostKeyFingerprint: String
    public var controlAuthSecret: String
    public var autoEndpoints: [MirageHostBootstrapEndpoint]
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
        autoEndpoints: [MirageHostBootstrapEndpoint] = [],
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

    public static func makeDefaultControlAuthSecret() -> String {
        let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }
}
