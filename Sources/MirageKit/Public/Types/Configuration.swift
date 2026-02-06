//
//  Configuration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics
import Foundation

// MARK: - Encoder Configuration

/// Configuration for video encoding on the host
public struct MirageEncoderConfiguration: Sendable {
    /// Video codec to use
    public var codec: MirageVideoCodec

    /// Target frame rate
    public var targetFrameRate: Int

    /// Keyframe interval (in frames)
    public var keyFrameInterval: Int

    /// Color space for encoding
    public var colorSpace: MirageColorSpace

    /// Scale factor for retina displays
    public var scaleFactor: CGFloat

    /// Pixel format for capture and encode
    public var pixelFormat: MiragePixelFormat
    /// Capture queue depth override for ScreenCaptureKit (nil uses adaptive defaults)
    public var captureQueueDepth: Int?

    /// Target bitrate in bits per second
    public var bitrate: Int?

    /// Internal derived quality levels used by the encoder.
    package var frameQuality: Float
    package var keyframeQuality: Float

    public init(
        codec: MirageVideoCodec = .hevc,
        targetFrameRate: Int = 60,
        keyFrameInterval: Int = 1800,
        colorSpace: MirageColorSpace = .displayP3,
        scaleFactor: CGFloat = 2.0,
        pixelFormat: MiragePixelFormat = .p010,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    ) {
        self.codec = codec
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.colorSpace = colorSpace
        self.scaleFactor = scaleFactor
        self.pixelFormat = pixelFormat
        self.captureQueueDepth = captureQueueDepth
        self.bitrate = bitrate
        frameQuality = 0.8
        keyframeQuality = 0.65
    }

    /// Default configuration for high-bandwidth local network
    public static let highQuality = MirageEncoderConfiguration(
        targetFrameRate: 120,
        keyFrameInterval: 3600,
        pixelFormat: .p010,
        bitrate: 130_000_000
    )

    /// Default configuration for lower bandwidth
    public static let balanced = MirageEncoderConfiguration(
        targetFrameRate: 120,
        keyFrameInterval: 3600,
        pixelFormat: .nv12,
        bitrate: 100_000_000
    )

    /// Create a copy with multiple encoder setting overrides
    /// Use this for full client control over encoding parameters
    public func withOverrides(
        keyFrameInterval: Int? = nil,
        pixelFormat: MiragePixelFormat? = nil,
        colorSpace: MirageColorSpace? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    )
    -> MirageEncoderConfiguration {
        var config = self
        if let interval = keyFrameInterval { config.keyFrameInterval = interval }
        if let pixelFormat { config.pixelFormat = pixelFormat }
        if let colorSpace { config.colorSpace = colorSpace }
        if let captureQueueDepth { config.captureQueueDepth = captureQueueDepth }
        if let bitrate { config.bitrate = bitrate }
        return config
    }

    /// Create a copy with a different target frame rate
    /// Use this to override the default based on client capability
    public func withTargetFrameRate(_ newFrameRate: Int) -> MirageEncoderConfiguration {
        var config = self
        config.targetFrameRate = newFrameRate
        return config
    }
}

/// Optional overrides for encoder settings supplied by the client.
public struct MirageEncoderOverrides: Sendable, Codable {
    public var keyFrameInterval: Int?
    public var pixelFormat: MiragePixelFormat?
    public var colorSpace: MirageColorSpace?
    public var captureQueueDepth: Int?
    public var bitrate: Int?

    public init(
        keyFrameInterval: Int? = nil,
        pixelFormat: MiragePixelFormat? = nil,
        colorSpace: MirageColorSpace? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    ) {
        self.keyFrameInterval = keyFrameInterval
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace
        self.captureQueueDepth = captureQueueDepth
        self.bitrate = bitrate
    }
}

/// Video codec options
public enum MirageVideoCodec: String, Sendable, CaseIterable, Codable {
    case hevc = "hvc1"
    case h264 = "avc1"

    public var displayName: String {
        switch self {
        case .hevc: "HEVC (H.265)"
        case .h264: "H.264"
        }
    }
}

/// Color space options
public enum MirageColorSpace: String, Sendable, CaseIterable, Codable {
    case sRGB
    case displayP3 = "P3"
    // TODO: HDR support - requires proper virtual display EDR configuration
    // case hdr = "HDR"  // Rec. 2020 with PQ transfer function

    public var displayName: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
            // case .hdr: return "HDR (Rec. 2020)"
        }
    }
}

/// Pixel format for stream capture and encoding.
public enum MiragePixelFormat: String, Sendable, CaseIterable, Codable {
    case p010
    case bgr10a2
    case bgra8
    case nv12

    public var displayName: String {
        switch self {
        case .p010: "10-bit (P010 4:2:0)"
        case .bgr10a2: "10-bit (ARGB2101010 4:4:4)"
        case .bgra8: "8-bit (BGRA 4:4:4)"
        case .nv12: "8-bit (NV12 4:2:0)"
        }
    }
}

// MARK: - Network Configuration

/// Configuration for network connections
public struct MirageNetworkConfiguration: Sendable {
    /// Bonjour service type
    public var serviceType: String

    /// Control channel port (TCP) - 0 for auto-assign
    public var controlPort: UInt16

    /// Data channel port (UDP) - 0 for auto-assign
    public var dataPort: UInt16

    /// Whether to enable TLS encryption
    public var enableTLS: Bool

    /// Connection timeout in seconds
    public var connectionTimeout: TimeInterval

    /// Maximum UDP packet size (Mirage header + payload).
    /// Keep <= 1232 to stay under IPv6 minimum MTU once IP/UDP headers are added.
    public var maxPacketSize: Int

    /// Whether to enable peer-to-peer WiFi (AWDL) for discovery and connections.
    /// When enabled, devices can connect directly without needing the same WiFi network.
    public var enablePeerToPeer: Bool

    public init(
        serviceType: String = MirageKit.serviceType,
        controlPort: UInt16 = 0,
        dataPort: UInt16 = 0,
        enableTLS: Bool = true,
        connectionTimeout: TimeInterval = 10,
        maxPacketSize: Int = mirageDefaultMaxPacketSize,
        enablePeerToPeer: Bool = true
    ) {
        self.serviceType = serviceType
        self.controlPort = controlPort
        self.dataPort = dataPort
        self.enableTLS = enableTLS
        self.connectionTimeout = connectionTimeout
        self.maxPacketSize = maxPacketSize
        self.enablePeerToPeer = enablePeerToPeer
    }

    public static let `default` = MirageNetworkConfiguration()
}

// MARK: - Latency Mode

/// Latency preference for stream buffering behavior.
public enum MirageStreamLatencyMode: String, Sendable, CaseIterable, Codable {
    case lowestLatency
    case balanced
    case smoothest

    public var displayName: String {
        switch self {
        case .lowestLatency: "Lowest Latency"
        case .balanced: "Balanced"
        case .smoothest: "Smoothest"
        }
    }
}
