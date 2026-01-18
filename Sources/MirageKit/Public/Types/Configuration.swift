import Foundation
import CoreGraphics

// MARK: - Encoder Configuration

/// Configuration for video encoding on the host
public struct MirageEncoderConfiguration: Sendable {
    /// Video codec to use
    public var codec: MirageVideoCodec

    /// Maximum bitrate in bits per second
    public var maxBitrate: Int

    /// Minimum bitrate in bits per second
    public var minBitrate: Int

    /// Target frame rate
    public var targetFrameRate: Int

    /// Keyframe interval (in frames)
    public var keyFrameInterval: Int

    /// Color space for encoding
    public var colorSpace: MirageColorSpace

    /// Scale factor for retina displays
    public var scaleFactor: CGFloat

    /// Quality level for encoded frames (0.0-1.0, where 1.0 is maximum quality)
    /// Lower values reduce frame size significantly with minimal visual impact
    /// Default 0.8 reduces frame size by ~40-50% for better UDP reliability
    public var keyframeQuality: Float

    public init(
        codec: MirageVideoCodec = .hevc,
        maxBitrate: Int = 100_000_000,
        minBitrate: Int = 5_000_000,
        targetFrameRate: Int = 60,
        keyFrameInterval: Int = 600,
        colorSpace: MirageColorSpace = .displayP3,
        scaleFactor: CGFloat = 2.0,
        keyframeQuality: Float = 0.8  // Lower quality yields smaller frames for better UDP reliability
    ) {
        self.codec = codec
        self.maxBitrate = maxBitrate
        self.minBitrate = minBitrate
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.colorSpace = colorSpace
        self.scaleFactor = scaleFactor
        self.keyframeQuality = keyframeQuality
    }

    /// Default configuration for high-bandwidth local network
    public static let highQuality = MirageEncoderConfiguration(
        maxBitrate: 200_000_000,
        minBitrate: 50_000_000,
        targetFrameRate: 120,
        keyFrameInterval: 600
    )

    /// Default configuration for lower bandwidth
    public static let balanced = MirageEncoderConfiguration(
        maxBitrate: 50_000_000,
        minBitrate: 10_000_000,
        targetFrameRate: 120,
        keyFrameInterval: 600
    )

    /// Configuration optimized for low-latency text applications
    /// Achieves NVIDIA GameStream-competitive latency through:
    /// - Longer keyframe interval (fewer large frames to fragment)
    /// - Lower quality (30-50% smaller frames)
    /// - Aggressive frame skipping (always-latest-frame strategy)
    /// Best for: IDEs, text editors, terminals - any app where responsiveness matters
    public static let lowLatency = MirageEncoderConfiguration(
        codec: .hevc,
        maxBitrate: 150_000_000,
        minBitrate: 20_000_000,
        targetFrameRate: 120,
        keyFrameInterval: 600,
        colorSpace: .displayP3,
        scaleFactor: 2.0,
        keyframeQuality: 0.85
    )

    /// Create a copy with a different max bitrate
    /// Use this to override the default bitrate based on client network capabilities
    public func withMaxBitrate(_ newMaxBitrate: Int) -> MirageEncoderConfiguration {
        var config = self
        config.maxBitrate = newMaxBitrate
        // Also update minBitrate to be proportional (10% of max as a floor)
        config.minBitrate = max(5_000_000, newMaxBitrate / 10)
        return config
    }

    /// Create a copy with multiple encoder setting overrides
    /// Use this for full client control over encoding parameters
    public func withOverrides(
        maxBitrate: Int? = nil,
        keyFrameInterval: Int? = nil,
        keyframeQuality: Float? = nil
    ) -> MirageEncoderConfiguration {
        var config = self
        if let bitrate = maxBitrate {
            config.maxBitrate = bitrate
            config.minBitrate = max(5_000_000, bitrate / 10)
        }
        if let interval = keyFrameInterval {
            config.keyFrameInterval = interval
        }
        if let quality = keyframeQuality {
            config.keyframeQuality = quality
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
/// Presets define fixed encoder caps that can be overridden by the client.
public enum MirageQualityPreset: String, Sendable, CaseIterable, Codable {
    case ultra       // Highest bitrate
    case high        // High bitrate
    case medium      // Balanced bitrate
    case low         // Low bitrate
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
        switch self {
        case .ultra:
            return MirageEncoderConfiguration(
                maxBitrate: 200_000_000,
                keyframeQuality: 1.0
            )
        case .high:
            return MirageEncoderConfiguration(
                maxBitrate: isHighRefresh ? 130_000_000 : 100_000_000,
                keyframeQuality: isHighRefresh ? 0.88 : 0.95
            )
        case .medium:
            return MirageEncoderConfiguration(
                maxBitrate: isHighRefresh ? 85_000_000 : 50_000_000,
                keyframeQuality: isHighRefresh ? 0.60 : 0.75
            )
        case .low:
            return MirageEncoderConfiguration(
                maxBitrate: isHighRefresh ? 8_000_000 : 12_000_000,
                keyframeQuality: isHighRefresh ? 0.06 : 0.12
            )
        case .lowLatency:
            return .lowLatency
        }
    }

}
