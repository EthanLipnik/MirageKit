//
//  MirageBootstrapMetadata.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/21/26.
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

    /// Creates a bootstrap endpoint candidate.
    ///
    /// - Parameters:
    ///   - host: IP address or host name reachable by the client.
    ///   - port: Port used for SSH or daemon control, depending on context.
    ///   - source: Source that produced the endpoint (`user`, `auto`, or `lastSeen`).
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

    /// Creates Wake-on-LAN metadata.
    ///
    /// - Parameters:
    ///   - macAddress: Target NIC MAC address.
    ///   - broadcastAddresses: UDP broadcast destinations where packets are sent.
    ///
    /// - Note: Broadcast addresses are typically subnet broadcasts such as `192.168.1.255`.
    public init(macAddress: String, broadcastAddresses: [String]) {
        self.macAddress = macAddress
        self.broadcastAddresses = broadcastAddresses
    }
}

/// Bootstrap capability metadata stored with host records.
public struct MirageBootstrapMetadata: Codable, Hashable, Sendable {
    /// Metadata version for forward-compatible decoding.
    public static let currentVersion = 2

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
    /// Shared secret used by the authenticated bootstrap daemon control protocol.
    public let controlAuthSecret: String?
    /// Wake-on-LAN metadata when available.
    public let wakeOnLAN: MirageWakeOnLANInfo?

    /// Creates host bootstrap capability metadata.
    ///
    /// - Parameters:
    ///   - version: Metadata version. Keep default unless you are migrating schema.
    ///   - enabled: Whether host bootstrap is enabled by user policy.
    ///   - supportsPreloginDaemon: Whether daemon handoff APIs are available.
    ///   - supportsAutomaticUnlock: Whether host can complete unlock after SSH stage.
    ///   - endpoints: Candidate endpoints for bootstrap connection attempts.
    ///   - sshPort: Preferred SSH port.
    ///   - controlPort: Preferred daemon control port.
    ///   - sshHostKeyFingerprint: Optional pinned SSH host key fingerprint.
    ///   - controlAuthSecret: Shared secret for authenticated bootstrap daemon control requests.
    ///   - wakeOnLAN: Optional Wake-on-LAN payload data.
    ///
    /// Example:
    /// ```swift
    /// let metadata = MirageBootstrapMetadata(
    ///     enabled: true,
    ///     supportsPreloginDaemon: true,
    ///     supportsAutomaticUnlock: true,
    ///     endpoints: [.init(host: "192.168.1.10", port: 22, source: .auto)],
    ///     sshPort: 22,
    ///     controlPort: 9849,
    ///     sshHostKeyFingerprint: "SHA256:...",
    ///     controlAuthSecret: "base64-secret",
    ///     wakeOnLAN: .init(macAddress: "AA:BB:CC:DD:EE:FF", broadcastAddresses: ["192.168.1.255"])
    /// )
    /// ```
    public init(
        version: Int = MirageBootstrapMetadata.currentVersion,
        enabled: Bool,
        supportsPreloginDaemon: Bool,
        supportsAutomaticUnlock: Bool,
        endpoints: [MirageBootstrapEndpoint],
        sshPort: UInt16?,
        controlPort: UInt16?,
        sshHostKeyFingerprint: String? = nil,
        controlAuthSecret: String? = nil,
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
        self.controlAuthSecret = controlAuthSecret
        self.wakeOnLAN = wakeOnLAN
    }
}
