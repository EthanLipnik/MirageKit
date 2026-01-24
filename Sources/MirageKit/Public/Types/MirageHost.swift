//
//  MirageHost.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Network

/// Represents a discovered host on the network
public struct MirageHost: Identifiable, Hashable, Sendable {
    /// Unique identifier for this host
    public let id: UUID

    /// Display name of the host
    public let name: String

    /// Device type (Mac, etc.)
    public let deviceType: DeviceType

    /// Network endpoint for connection
    public let endpoint: NWEndpoint

    /// Host capabilities
    public let capabilities: MirageHostCapabilities

    public init(
        id: UUID,
        name: String,
        deviceType: DeviceType,
        endpoint: NWEndpoint,
        capabilities: MirageHostCapabilities
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.endpoint = endpoint
        self.capabilities = capabilities
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: MirageHost, rhs: MirageHost) -> Bool {
        lhs.id == rhs.id
    }
}

/// Device type enumeration
public enum DeviceType: String, Codable, Sendable {
    case mac
    case iPad
    case iPhone
    case vision
    case unknown

    public var displayName: String {
        switch self {
        case .mac: return "Mac"
        case .iPad: return "iPad"
        case .iPhone: return "iPhone"
        case .vision: return "Apple Vision"
        case .unknown: return "Unknown"
        }
    }

    public var systemImage: String {
        switch self {
        case .mac: return "desktopcomputer"
        case .iPad: return "ipad"
        case .iPhone: return "iphone"
        case .vision: return "visionpro"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Host capabilities advertised via Bonjour
public struct MirageHostCapabilities: Codable, Hashable, Sendable {
    /// Maximum number of simultaneous streams
    public let maxStreams: Int

    /// Whether HEVC encoding is supported
    public let supportsHEVC: Bool

    /// Whether P3 color space is supported
    public let supportsP3ColorSpace: Bool

    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// Whether HDR (Rec. 2020 with PQ) is supported
    // public let supportsHDR: Bool

    /// Maximum supported frame rate
    public let maxFrameRate: Int

    /// Protocol version
    public let protocolVersion: Int

    public init(
        maxStreams: Int = 4,
        supportsHEVC: Bool = true,
        supportsP3ColorSpace: Bool = true,
        // supportsHDR: Bool = true,
        maxFrameRate: Int = 120,
        protocolVersion: Int = Int(MirageKit.protocolVersion)
    ) {
        self.maxStreams = maxStreams
        self.supportsHEVC = supportsHEVC
        self.supportsP3ColorSpace = supportsP3ColorSpace
        // self.supportsHDR = supportsHDR
        self.maxFrameRate = maxFrameRate
        self.protocolVersion = protocolVersion
    }

    /// Encode to TXT record data for Bonjour
    public func toTXTRecord() -> [String: String] {
        [
            "maxStreams": String(maxStreams),
            "hevc": supportsHEVC ? "1" : "0",
            "p3": supportsP3ColorSpace ? "1" : "0",
            // "hdr": supportsHDR ? "1" : "0",
            "maxFps": String(maxFrameRate),
            "proto": String(protocolVersion)
        ]
    }

    /// Decode from TXT record data
    public static func from(txtRecord: [String: String]) -> MirageHostCapabilities {
        MirageHostCapabilities(
            maxStreams: Int(txtRecord["maxStreams"] ?? "4") ?? 4,
            supportsHEVC: txtRecord["hevc"] == "1",
            supportsP3ColorSpace: txtRecord["p3"] == "1"
            // supportsHDR: txtRecord["hdr"] == "1",
            // maxFrameRate and protocolVersion use defaults
        )
    }
}
