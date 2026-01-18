import Foundation
import CoreGraphics

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

    /// Minimum target bitrate in bits per second
    public var minBitrate: Int?

    /// Maximum target bitrate in bits per second
    public var maxBitrate: Int?

    /// Quality level for inter frames (0.0-1.0, where 1.0 is maximum quality).
    /// Lower values reduce frame size significantly with minimal visual impact.
    public var frameQuality: Float

    /// Quality level for keyframes (0.0-1.0, where 1.0 is maximum quality).
    /// Keyframes are large and can cause queue spikes; keep this lower than frameQuality.
    public var keyframeQuality: Float

    public init(
        codec: MirageVideoCodec = .hevc,
        targetFrameRate: Int = 60,
        keyFrameInterval: Int = 1_800,
        colorSpace: MirageColorSpace = .displayP3,
        scaleFactor: CGFloat = 2.0,
        pixelFormat: MiragePixelFormat = .bgr10a2,
        minBitrate: Int? = nil,
        maxBitrate: Int? = nil,
        frameQuality: Float = 0.8,
        keyframeQuality: Float = 0.65
    ) {
        self.codec = codec
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.colorSpace = colorSpace
        self.scaleFactor = scaleFactor
        self.pixelFormat = pixelFormat
        self.minBitrate = minBitrate
        self.maxBitrate = maxBitrate
        self.frameQuality = frameQuality
        self.keyframeQuality = keyframeQuality
    }

    /// Default configuration for high-bandwidth local network
    public static let highQuality = MirageEncoderConfiguration(
        targetFrameRate: 120,
        keyFrameInterval: 3_600,
        pixelFormat: .bgr10a2,
        frameQuality: 1.0,
        keyframeQuality: 0.75
    )

    /// Default configuration for lower bandwidth
    public static let balanced = MirageEncoderConfiguration(
        targetFrameRate: 120,
        keyFrameInterval: 3_600,
        pixelFormat: .bgra8,
        frameQuality: 0.75,
        keyframeQuality: 0.65
    )

    /// Configuration optimized for low-latency text applications
    /// Achieves NVIDIA GameStream-competitive latency through:
    /// - Longer keyframe interval (fewer large frames to fragment)
    /// - Lower quality (30-50% smaller frames)
    /// - Aggressive frame skipping (always-latest-frame strategy)
    /// - 8-bit pixel format for faster encode
    /// Best for: IDEs, text editors, terminals - any app where responsiveness matters
    public static let lowLatency = MirageEncoderConfiguration(
        codec: .hevc,
        targetFrameRate: 120,
        keyFrameInterval: 3_600,
        colorSpace: .sRGB,
        scaleFactor: 2.0,
        pixelFormat: .bgra8,
        frameQuality: 0.85,
        keyframeQuality: 0.65
    )

    /// Create a copy with multiple encoder setting overrides
    /// Use this for full client control over encoding parameters
    public func withOverrides(
        keyFrameInterval: Int? = nil,
        frameQuality: Float? = nil,
        keyframeQuality: Float? = nil,
        pixelFormat: MiragePixelFormat? = nil,
        colorSpace: MirageColorSpace? = nil,
        minBitrate: Int? = nil,
        maxBitrate: Int? = nil
    ) -> MirageEncoderConfiguration {
        var config = self
        if let interval = keyFrameInterval {
            config.keyFrameInterval = interval
        }
        if let quality = frameQuality {
            config.frameQuality = quality
        }
        if let quality = keyframeQuality {
            config.keyframeQuality = quality
        }
        if frameQuality != nil, keyframeQuality == nil {
            config.keyframeQuality = min(config.keyframeQuality, config.frameQuality)
        }
        if let pixelFormat {
            config.pixelFormat = pixelFormat
        }
        if let colorSpace {
            config.colorSpace = colorSpace
        }
        if let minBitrate {
            config.minBitrate = minBitrate
        }
        if let maxBitrate {
            config.maxBitrate = maxBitrate
        }
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

/// Video codec options
public enum MirageVideoCodec: String, Sendable, CaseIterable, Codable {
    case hevc = "hvc1"
    case h264 = "avc1"

    public var displayName: String {
        switch self {
        case .hevc: return "HEVC (H.265)"
        case .h264: return "H.264"
        }
    }
}

/// Color space options
public enum MirageColorSpace: String, Sendable, CaseIterable, Codable {
    case sRGB = "sRGB"
    case displayP3 = "P3"
    // TODO: HDR support - requires proper virtual display EDR configuration
    // case hdr = "HDR"  // Rec. 2020 with PQ transfer function

    public var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        // case .hdr: return "HDR (Rec. 2020)"
        }
    }
}

/// Pixel format for stream capture and encoding.
public enum MiragePixelFormat: String, Sendable, CaseIterable, Codable {
    case p010
    case bgr10a2
    case bgra8

    public var displayName: String {
        switch self {
        case .p010: return "10-bit (P010)"
        case .bgr10a2: return "10-bit (ARGB2101010)"
        case .bgra8: return "8-bit (BGRA)"
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
        maxPacketSize: Int = MirageDefaultMaxPacketSize,
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

// MARK: - Quality Presets

/// Quality preset for quick configuration.
/// Presets define encoder quality defaults that can be overridden by the client.
public enum MirageQualityPreset: String, Sendable, CaseIterable, Codable {
    case ultra       // Highest quality
    case high        // High quality
    case medium      // Balanced quality
    case low         // Low quality
    case lowLatency  // Optimized for text apps - aggressive frame skipping, full quality

    public var displayName: String {
        switch self {
        case .ultra: return "Ultra"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .lowLatency: return "Low Latency"
        }
    }

    public var encoderConfiguration: MirageEncoderConfiguration {
        encoderConfiguration(for: 60)
    }

    public func encoderConfiguration(for frameRate: Int) -> MirageEncoderConfiguration {
        let isHighRefresh = frameRate >= 120
        let keyFrameInterval = frameRate * 30
        func bitrateMbps(_ value: Int) -> Int {
            value * 1_000_000
        }
        switch self {
        case .ultra:
            return MirageEncoderConfiguration(
                keyFrameInterval: keyFrameInterval,
                pixelFormat: .bgr10a2,
                minBitrate: bitrateMbps(200),
                maxBitrate: bitrateMbps(200),
                frameQuality: 1.0,
                keyframeQuality: 0.75
            )
        case .high:
            return MirageEncoderConfiguration(
                keyFrameInterval: keyFrameInterval,
                pixelFormat: .bgr10a2,
                minBitrate: bitrateMbps(isHighRefresh ? 130 : 100),
                maxBitrate: bitrateMbps(isHighRefresh ? 130 : 100),
                frameQuality: isHighRefresh ? 0.88 : 0.95,
                keyframeQuality: isHighRefresh ? 0.70 : 0.80
            )
        case .medium:
            return MirageEncoderConfiguration(
                keyFrameInterval: keyFrameInterval,
                colorSpace: .displayP3,
                pixelFormat: .bgr10a2,
                minBitrate: bitrateMbps(isHighRefresh ? 85 : 50),
                maxBitrate: bitrateMbps(isHighRefresh ? 85 : 50),
                frameQuality: isHighRefresh ? 0.70 : 0.80,
                keyframeQuality: isHighRefresh ? 0.60 : 0.70
            )
        case .low:
            return MirageEncoderConfiguration(
                keyFrameInterval: keyFrameInterval,
                colorSpace: .sRGB,
                pixelFormat: .bgra8,
                minBitrate: bitrateMbps(isHighRefresh ? 8 : 12),
                maxBitrate: bitrateMbps(isHighRefresh ? 8 : 12),
                frameQuality: isHighRefresh ? 0.18 : 0.24,
                keyframeQuality: isHighRefresh ? 0.18 : 0.24
            )
        case .lowLatency:
            return MirageEncoderConfiguration(
                keyFrameInterval: keyFrameInterval,
                colorSpace: .sRGB,
                pixelFormat: .bgra8,
                minBitrate: bitrateMbps(150),
                maxBitrate: bitrateMbps(150),
                frameQuality: 0.85,
                keyframeQuality: 0.65
            )
        }
    }

}
