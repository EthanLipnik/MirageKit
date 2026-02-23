//
//  MirageBootstrapMetadata.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Bootstrap metadata shared between host publication and client recovery logic.
//

import Foundation

/// Origin of a bootstrap endpoint.
public enum MirageBootstrapEndpointSource: String, Codable, CaseIterable, Sendable {
    /// Explicit endpoint entered in host settings.
    case user
    /// Endpoint inferred from host network interfaces.
    case auto
    /// Endpoint remembered from a previous successful bootstrap.
    case lastSeen
}

/// Network endpoint used for wake/unlock bootstrap.
public struct MirageBootstrapEndpoint: Codable, Hashable, Sendable {
    /// Hostname or IP address.
    public let host: String
    /// TCP port used for SSH or control bootstrap.
    public let port: UInt16
    /// Source of the endpoint.
    public let source: MirageBootstrapEndpointSource

    public init(
        host: String,
        port: UInt16,
        source: MirageBootstrapEndpointSource
    ) {
        self.host = host
        self.port = port
        self.source = source
    }
}

/// Wake-on-LAN metadata published by host.
public struct MirageWakeOnLANInfo: Codable, Hashable, Sendable {
    /// Target NIC MAC address used to build magic packets.
    public let macAddress: String
    /// Broadcast targets where magic packets should be sent.
    public let broadcastAddresses: [String]

    public init(macAddress: String, broadcastAddresses: [String]) {
        self.macAddress = macAddress
        self.broadcastAddresses = broadcastAddresses
    }
}

/// Bootstrap capability metadata stored with host records.
public struct MirageBootstrapMetadata: Codable, Hashable, Sendable {
    /// Metadata version for forward-compatible decoding.
    public static let currentVersion = 1

    /// Metadata schema version.
    public let version: Int
    /// Whether host opted into wake/unlock bootstrap.
    public let enabled: Bool
    /// Whether host supports pre-login daemon handoff.
    public let supportsPreloginDaemon: Bool
    /// Whether host supports automatic unlock completion after SSH volume unlock.
    public let supportsAutomaticUnlock: Bool
    /// SSH/bootstrap endpoints published by host.
    public let endpoints: [MirageBootstrapEndpoint]
    /// Preferred SSH port for FileVault unlock over SSH.
    public let sshPort: UInt16?
    /// Optional bootstrap control port for daemon handoff.
    public let controlPort: UInt16?
    /// Optional pinned SSH host key fingerprint (`SHA256:...`) for bootstrap trust.
    public let sshHostKeyFingerprint: String?
    /// Wake-on-LAN metadata when available.
    public let wakeOnLAN: MirageWakeOnLANInfo?

    public init(
        version: Int = MirageBootstrapMetadata.currentVersion,
        enabled: Bool,
        supportsPreloginDaemon: Bool,
        supportsAutomaticUnlock: Bool,
        endpoints: [MirageBootstrapEndpoint],
        sshPort: UInt16?,
        controlPort: UInt16?,
        sshHostKeyFingerprint: String? = nil,
        wakeOnLAN: MirageWakeOnLANInfo?
    ) {
        self.version = version
        self.enabled = enabled
        self.supportsPreloginDaemon = supportsPreloginDaemon
        self.supportsAutomaticUnlock = supportsAutomaticUnlock
        self.endpoints = endpoints
        self.sshPort = sshPort
        self.controlPort = controlPort
        self.sshHostKeyFingerprint = sshHostKeyFingerprint
        self.wakeOnLAN = wakeOnLAN
    }
}
