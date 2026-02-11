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
        case .mac: "Mac"
        case .iPad: "iPad"
        case .iPhone: "iPhone"
        case .vision: "Apple Vision"
        case .unknown: "Unknown"
        }
    }

    public var systemImage: String {
        switch self {
        case .mac: "desktopcomputer"
        case .iPad: "ipad"
        case .iPhone: "iphone"
        case .vision: "visionpro"
        case .unknown: "questionmark.circle"
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

    /// Stable device identifier for self-filtering (advertised via Bonjour TXT record)
    public let deviceID: UUID?

    /// Stable identity key identifier for signed handshake verification.
    public let identityKeyID: String?

    /// Host hardware model identifier (for example, MacBookPro18,3).
    public let hardwareModelIdentifier: String?

    /// Host-resolved CoreTypes hardware icon basename (for example, com.apple.macbookpro-16-2021-silver.icns).
    public let hardwareIconName: String?

    /// Host machine family hint used for symbol fallback (`macBook`, `iMac`, `macMini`, `macStudio`, `macPro`).
    public let hardwareMachineFamily: String?

    public init(
        maxStreams: Int = 4,
        supportsHEVC: Bool = true,
        supportsP3ColorSpace: Bool = true,
        // supportsHDR: Bool = true,
        maxFrameRate: Int = 120,
        protocolVersion: Int = Int(MirageKit.protocolVersion),
        deviceID: UUID? = nil,
        identityKeyID: String? = nil,
        hardwareModelIdentifier: String? = nil,
        hardwareIconName: String? = nil,
        hardwareMachineFamily: String? = nil
    ) {
        self.maxStreams = maxStreams
        self.supportsHEVC = supportsHEVC
        self.supportsP3ColorSpace = supportsP3ColorSpace
        // self.supportsHDR = supportsHDR
        self.maxFrameRate = maxFrameRate
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.identityKeyID = identityKeyID
        self.hardwareModelIdentifier = hardwareModelIdentifier
        self.hardwareIconName = hardwareIconName
        self.hardwareMachineFamily = hardwareMachineFamily
    }

    /// Encode to TXT record data for Bonjour
    public func toTXTRecord() -> [String: String] {
        var record: [String: String] = [
            "maxStreams": String(maxStreams),
            "hevc": supportsHEVC ? "1" : "0",
            "p3": supportsP3ColorSpace ? "1" : "0",
            // "hdr": supportsHDR ? "1" : "0",
            "maxFps": String(maxFrameRate),
            "proto": String(protocolVersion),
        ]

        // Add device ID for self-filtering
        if let deviceID { record["did"] = deviceID.uuidString }
        if let identityKeyID { record["ikid"] = identityKeyID }
        if let hardwareModelIdentifier { record["hwm"] = hardwareModelIdentifier }
        if let hardwareIconName { record["hwi"] = hardwareIconName }
        if let hardwareMachineFamily { record["hwf"] = hardwareMachineFamily }

        return record
    }

    /// Decode from TXT record data
    public static func from(txtRecord: [String: String]) -> MirageHostCapabilities {
        // Parse device ID if present
        var parsedDeviceID: UUID?
        if let didString = txtRecord["did"] { parsedDeviceID = UUID(uuidString: didString) }
        let parsedIdentityKeyID = txtRecord["ikid"]
        let parsedHardwareModelIdentifier = txtRecord["hwm"]
        let parsedHardwareIconName = txtRecord["hwi"]
        let parsedHardwareMachineFamily = txtRecord["hwf"]

        return MirageHostCapabilities(
            maxStreams: Int(txtRecord["maxStreams"] ?? "4") ?? 4,
            supportsHEVC: txtRecord["hevc"] == "1",
            supportsP3ColorSpace: txtRecord["p3"] == "1",
            // supportsHDR: txtRecord["hdr"] == "1",
            // maxFrameRate and protocolVersion use defaults
            deviceID: parsedDeviceID,
            identityKeyID: parsedIdentityKeyID,
            hardwareModelIdentifier: parsedHardwareModelIdentifier,
            hardwareIconName: parsedHardwareIconName,
            hardwareMachineFamily: parsedHardwareMachineFamily
        )
    }
}
