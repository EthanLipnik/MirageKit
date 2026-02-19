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

    /// User-selected stream bit depth.
    public var bitDepth: MirageVideoBitDepth

    /// Color space for encoding.
    package var colorSpace: MirageColorSpace

    /// Scale factor for retina displays
    public var scaleFactor: CGFloat

    /// Pixel format for capture and encode.
    package var pixelFormat: MiragePixelFormat
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
        bitDepth: MirageVideoBitDepth = .eightBit,
        scaleFactor: CGFloat = 2.0,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    ) {
        self.codec = codec
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.bitDepth = bitDepth
        colorSpace = Self.colorSpace(for: bitDepth)
        self.scaleFactor = scaleFactor
        pixelFormat = Self.pixelFormat(for: bitDepth)
        self.captureQueueDepth = captureQueueDepth
        self.bitrate = bitrate
        frameQuality = 0.8
        keyframeQuality = 0.65
    }

    package init(
        codec: MirageVideoCodec = .hevc,
        targetFrameRate: Int = 60,
        keyFrameInterval: Int = 1800,
        colorSpace: MirageColorSpace,
        scaleFactor: CGFloat = 2.0,
        pixelFormat: MiragePixelFormat,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    ) {
        self.codec = codec
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.bitDepth = Self.bitDepth(for: pixelFormat)
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
        bitrate: 130_000_000
    )

    /// Default configuration for lower bandwidth
    public static let balanced = MirageEncoderConfiguration(
        targetFrameRate: 120,
        keyFrameInterval: 3600,
        bitrate: 100_000_000
    )

    /// Create a copy with multiple encoder setting overrides
    /// Use this for full client control over encoding parameters
    public func withOverrides(
        keyFrameInterval: Int? = nil,
        bitDepth: MirageVideoBitDepth? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    )
    -> MirageEncoderConfiguration {
        var config = self
        if let interval = keyFrameInterval { config.keyFrameInterval = interval }
        if let bitDepth {
            config.bitDepth = bitDepth
            config.pixelFormat = Self.pixelFormat(for: bitDepth)
            config.colorSpace = Self.colorSpace(for: bitDepth)
        }
        if let captureQueueDepth { config.captureQueueDepth = captureQueueDepth }
        if let bitrate { config.bitrate = bitrate }
        return config
    }

    package func withInternalOverrides(
        keyFrameInterval: Int? = nil,
        pixelFormat: MiragePixelFormat? = nil,
        colorSpace: MirageColorSpace? = nil,
        bitDepth: MirageVideoBitDepth? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    ) -> MirageEncoderConfiguration {
        var config = self
        if let interval = keyFrameInterval { config.keyFrameInterval = interval }
        if let bitDepth {
            config.bitDepth = bitDepth
            config.pixelFormat = Self.pixelFormat(for: bitDepth)
            config.colorSpace = Self.colorSpace(for: bitDepth)
        }
        if let pixelFormat {
            let derivedBitDepth = Self.bitDepth(for: pixelFormat)
            config.bitDepth = derivedBitDepth
            config.pixelFormat = pixelFormat
            config.colorSpace = Self.colorSpace(for: derivedBitDepth)
        }
        if let colorSpace {
            let derivedBitDepth: MirageVideoBitDepth = colorSpace == .displayP3 ? .tenBit : .eightBit
            config.bitDepth = derivedBitDepth
            config.colorSpace = colorSpace
            if pixelFormat == nil {
                config.pixelFormat = Self.pixelFormat(for: derivedBitDepth)
            }
        }
        if let captureQueueDepth { config.captureQueueDepth = captureQueueDepth }
        if let bitrate { config.bitrate = bitrate }
        return config
    }

    package static func pixelFormat(for bitDepth: MirageVideoBitDepth) -> MiragePixelFormat {
        switch bitDepth {
        case .eightBit: .nv12
        case .tenBit: .p010
        }
    }

    package static func colorSpace(for bitDepth: MirageVideoBitDepth) -> MirageColorSpace {
        switch bitDepth {
        case .eightBit: .sRGB
        case .tenBit: .displayP3
        }
    }

    package static func bitDepth(for pixelFormat: MiragePixelFormat) -> MirageVideoBitDepth {
        switch pixelFormat {
        case .p010, .bgr10a2:
            .tenBit
        case .bgra8, .nv12:
            .eightBit
        }
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
    public var bitDepth: MirageVideoBitDepth?
    public var captureQueueDepth: Int?
    public var bitrate: Int?
    public var latencyMode: MirageStreamLatencyMode?
    public var allowRuntimeQualityAdjustment: Bool?
    public var lowLatencyHighResolutionCompressionBoost: Bool?
    public var disableResolutionCap: Bool

    public init(
        keyFrameInterval: Int? = nil,
        bitDepth: MirageVideoBitDepth? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        disableResolutionCap: Bool = false
    ) {
        self.keyFrameInterval = keyFrameInterval
        self.bitDepth = bitDepth
        self.captureQueueDepth = captureQueueDepth
        self.bitrate = bitrate
        self.latencyMode = latencyMode
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        self.disableResolutionCap = disableResolutionCap
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

/// Stream bit depth options.
public enum MirageVideoBitDepth: String, Sendable, CaseIterable, Codable {
    case eightBit = "8bit"
    case tenBit = "10bit"

    public var displayName: String {
        switch self {
        case .eightBit: "8-bit"
        case .tenBit: "10-bit"
        }
    }
}

/// Color space options
package enum MirageColorSpace: String, Sendable, CaseIterable, Codable {
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
package enum MiragePixelFormat: String, Sendable, CaseIterable, Codable {
    case p010
    case bgr10a2
    case bgra8
    case nv12

    public var displayName: String {
        switch self {
        case .p010: "10-bit (P010)"
        case .bgr10a2: "10-bit (ARGB2101010)"
        case .bgra8: "8-bit (BGRA)"
        case .nv12: "8-bit (NV12)"
        }
    }
}

// MARK: - Audio Configuration

/// Audio channel layout for streamed host audio.
public enum MirageAudioChannelLayout: String, Sendable, CaseIterable, Codable {
    case mono
    case stereo
    case surround51

    public var channelCount: Int {
        switch self {
        case .mono: 1
        case .stereo: 2
        case .surround51: 6
        }
    }

    public var displayName: String {
        switch self {
        case .mono: "Mono"
        case .stereo: "Stereo"
        case .surround51: "Surround (5.1)"
        }
    }
}

/// Audio quality mode for host audio streaming.
public enum MirageAudioQuality: String, Sendable, CaseIterable, Codable {
    case low
    case high
    case lossless

    public var displayName: String {
        switch self {
        case .low: "Low"
        case .high: "High"
        case .lossless: "Lossless"
        }
    }
}

/// Wire codec used for audio packets.
public enum MirageAudioCodec: UInt8, Sendable, Codable {
    case aacLC = 1
    case pcm16LE = 2
}

/// Client-selected audio streaming configuration.
public struct MirageAudioConfiguration: Sendable, Codable, Equatable {
    /// Whether host audio streaming is enabled.
    public var enabled: Bool
    /// Requested channel layout.
    public var channelLayout: MirageAudioChannelLayout
    /// Requested quality mode.
    public var quality: MirageAudioQuality

    public init(
        enabled: Bool = true,
        channelLayout: MirageAudioChannelLayout = .stereo,
        quality: MirageAudioQuality = .high
    ) {
        self.enabled = enabled
        self.channelLayout = channelLayout
        self.quality = quality
    }

    public static let `default` = MirageAudioConfiguration()
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
    case auto
    case smoothest

    public var displayName: String {
        switch self {
        case .lowestLatency: "Lowest Latency"
        case .auto: "Auto"
        case .smoothest: "Smoothest"
        }
    }

    public var detailDescription: String {
        switch self {
        case .smoothest:
            "Targets 60Hz continuously, prioritizing visual cadence over interaction latency with deeper buffering and frame hold/repeat when needed."
        case .lowestLatency:
            "Minimizes capture to encode to decode to display latency at all times using minimal buffering and immediate latest-frame presentation, even when FPS drops."
        case .auto:
            "Uses Smoothest as baseline, then switches to latency-first only during qualifying text-entry key bursts; mouse input and keyboard shortcuts do not trigger."
        }
    }
}
