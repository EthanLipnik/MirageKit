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

    /// User-selected stream color depth preset.
    public var colorDepth: MirageStreamColorDepth

    /// Internal derived stream bit depth.
    package var bitDepth: MirageVideoBitDepth

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
        colorDepth: MirageStreamColorDepth = .standard,
        scaleFactor: CGFloat = 2.0,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    ) {
        self.codec = codec
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.colorDepth = colorDepth
        let descriptor = Self.descriptor(for: colorDepth)
        bitDepth = descriptor.bitDepth
        colorSpace = descriptor.colorSpace
        self.scaleFactor = scaleFactor
        pixelFormat = descriptor.primaryPixelFormat
        self.captureQueueDepth = captureQueueDepth
        self.bitrate = bitrate
        frameQuality = 0.8
        keyframeQuality = 0.65
    }

    package init(
        codec: MirageVideoCodec = .hevc,
        targetFrameRate: Int = 60,
        keyFrameInterval: Int = 1800,
        bitDepth: MirageVideoBitDepth,
        scaleFactor: CGFloat = 2.0,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    ) {
        self.init(
            codec: codec,
            targetFrameRate: targetFrameRate,
            keyFrameInterval: keyFrameInterval,
            colorDepth: Self.defaultColorDepth(for: bitDepth),
            scaleFactor: scaleFactor,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate
        )
    }

    package init(
        codec: MirageVideoCodec = .hevc,
        targetFrameRate: Int = 60,
        keyFrameInterval: Int = 1800,
        colorDepth: MirageStreamColorDepth,
        colorSpace: MirageColorSpace,
        scaleFactor: CGFloat = 2.0,
        pixelFormat: MiragePixelFormat,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    ) {
        self.codec = codec
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.colorDepth = colorDepth
        self.bitDepth = Self.bitDepth(for: pixelFormat)
        self.colorSpace = colorSpace
        self.scaleFactor = scaleFactor
        self.pixelFormat = pixelFormat
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
        self.init(
            codec: codec,
            targetFrameRate: targetFrameRate,
            keyFrameInterval: keyFrameInterval,
            colorDepth: Self.descriptor(for: pixelFormat).colorDepth,
            colorSpace: colorSpace,
            scaleFactor: scaleFactor,
            pixelFormat: pixelFormat,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate
        )
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
        colorDepth: MirageStreamColorDepth? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    )
    -> MirageEncoderConfiguration {
        var config = self
        if let interval = keyFrameInterval { config.keyFrameInterval = interval }
        if let colorDepth {
            config.apply(colorDepth: colorDepth)
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
        colorDepth: MirageStreamColorDepth? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    ) -> MirageEncoderConfiguration {
        var config = self
        if let interval = keyFrameInterval { config.keyFrameInterval = interval }
        if let colorDepth {
            config.apply(colorDepth: colorDepth)
        }
        if let bitDepth {
            config.bitDepth = bitDepth
            config.colorDepth = Self.defaultColorDepth(for: bitDepth)
            config.pixelFormat = Self.pixelFormat(for: bitDepth)
            config.colorSpace = Self.colorSpace(for: bitDepth)
        }
        if let pixelFormat {
            let descriptor = Self.descriptor(for: pixelFormat)
            config.colorDepth = descriptor.colorDepth
            config.bitDepth = descriptor.bitDepth
            config.pixelFormat = pixelFormat
            config.colorSpace = descriptor.colorSpace
        }
        if let colorSpace {
            config.colorSpace = colorSpace
        }
        if let captureQueueDepth { config.captureQueueDepth = captureQueueDepth }
        if let bitrate { config.bitrate = bitrate }
        return config
    }

    package mutating func apply(colorDepth: MirageStreamColorDepth) {
        let descriptor = Self.descriptor(for: colorDepth)
        self.colorDepth = colorDepth
        bitDepth = descriptor.bitDepth
        colorSpace = descriptor.colorSpace
        pixelFormat = descriptor.primaryPixelFormat
    }

    package static func descriptor(for colorDepth: MirageStreamColorDepth) -> MirageColorDepthDescriptor {
        switch colorDepth {
        case .standard:
            MirageColorDepthDescriptor(
                colorDepth: .standard,
                bitDepth: .eightBit,
                colorSpace: .sRGB,
                chromaSampling: .yuv420,
                capturePixelFormats: [.nv12, .bgra8],
                encoderProfileCandidates: [.hevcMain],
                decoderPreferredPixelFormats: [.nv12, .bgra8]
            )
        case .pro:
            MirageColorDepthDescriptor(
                colorDepth: .pro,
                bitDepth: .tenBit,
                colorSpace: .displayP3,
                chromaSampling: .yuv420,
                capturePixelFormats: [.p010, .bgr10a2],
                encoderProfileCandidates: [.hevcMain10],
                decoderPreferredPixelFormats: [.p010, .bgr10a2]
            )
        case .ultra:
            MirageColorDepthDescriptor(
                colorDepth: .ultra,
                bitDepth: .tenBit,
                colorSpace: .displayP3,
                chromaSampling: .yuv444,
                capturePixelFormats: [.xf44, .p010, .bgr10a2],
                encoderProfileCandidates: [.hevcMain42210, .hevcMain10],
                decoderPreferredPixelFormats: [.p010, .bgr10a2]
            )
        }
    }

    package static func descriptor(for pixelFormat: MiragePixelFormat) -> MirageColorDepthDescriptor {
        switch pixelFormat {
        case .xf44:
            descriptor(for: .ultra)
        case .p010,
             .bgr10a2:
            descriptor(for: .pro)
        case .bgra8,
             .nv12:
            descriptor(for: .standard)
        }
    }

    package static func descriptor(for colorSpace: MirageColorSpace) -> MirageColorDepthDescriptor {
        switch colorSpace {
        case .displayP3:
            descriptor(for: .pro)
        case .sRGB:
            descriptor(for: .standard)
        }
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
        case .p010, .bgr10a2, .xf44:
            .tenBit
        case .bgra8, .nv12:
            .eightBit
        }
    }

    package static func defaultColorDepth(for bitDepth: MirageVideoBitDepth) -> MirageStreamColorDepth {
        switch bitDepth {
        case .eightBit:
            .standard
        case .tenBit:
            .pro
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
    public var colorDepth: MirageStreamColorDepth?
    public var captureQueueDepth: Int?
    public var bitrate: Int?
    public var latencyMode: MirageStreamLatencyMode?
    public var performanceMode: MirageStreamPerformanceMode?
    public var allowRuntimeQualityAdjustment: Bool?
    public var lowLatencyHighResolutionCompressionBoost: Bool?
    public var temporaryDegradationMode: MirageTemporaryDegradationMode?
    public var disableResolutionCap: Bool
    /// Maximum bitrate the in-stream adaptation governor may ramp toward.
    /// When set, the governor can increase bitrate beyond the initial `bitrate`
    /// value up to this ceiling based on in-stream probe results.
    public var bitrateAdaptationCeiling: Int?
    /// Maximum encoded width in pixels. When set, the host computes the stream
    /// scale from these dimensions and the actual capture resolution instead of
    /// using the client-provided stream scale for virtual display sizing.
    public var encoderMaxWidth: Int?
    /// Maximum encoded height in pixels.
    public var encoderMaxHeight: Int?

    public init(
        keyFrameInterval: Int? = nil,
        colorDepth: MirageStreamColorDepth? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        performanceMode: MirageStreamPerformanceMode? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        temporaryDegradationMode: MirageTemporaryDegradationMode? = nil,
        disableResolutionCap: Bool = false,
        bitrateAdaptationCeiling: Int? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil
    ) {
        self.keyFrameInterval = keyFrameInterval
        self.colorDepth = colorDepth
        self.captureQueueDepth = captureQueueDepth
        self.bitrate = bitrate
        self.latencyMode = latencyMode
        self.performanceMode = performanceMode
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        self.temporaryDegradationMode = temporaryDegradationMode
        self.disableResolutionCap = disableResolutionCap
        self.bitrateAdaptationCeiling = bitrateAdaptationCeiling
        self.encoderMaxWidth = encoderMaxWidth
        self.encoderMaxHeight = encoderMaxHeight
    }

    package init(
        bitDepth: MirageVideoBitDepth,
        keyFrameInterval: Int? = nil,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        performanceMode: MirageStreamPerformanceMode? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        temporaryDegradationMode: MirageTemporaryDegradationMode? = nil,
        disableResolutionCap: Bool = false
    ) {
        self.init(
            keyFrameInterval: keyFrameInterval,
            colorDepth: MirageEncoderConfiguration.defaultColorDepth(for: bitDepth),
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate,
            latencyMode: latencyMode,
            performanceMode: performanceMode,
            allowRuntimeQualityAdjustment: allowRuntimeQualityAdjustment,
            lowLatencyHighResolutionCompressionBoost: lowLatencyHighResolutionCompressionBoost,
            temporaryDegradationMode: temporaryDegradationMode,
            disableResolutionCap: disableResolutionCap
        )
    }
}

/// Stream color depth presets.
public enum MirageStreamColorDepth: String, Sendable, CaseIterable, Codable {
    case standard
    case pro
    case ultra

    public static let orderedCases: [MirageStreamColorDepth] = [.standard, .pro, .ultra]

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .pro: "Pro"
        case .ultra: "Ultra"
        }
    }

    public var nextLowerFallback: MirageStreamColorDepth? {
        switch self {
        case .standard:
            nil
        case .pro:
            .standard
        case .ultra:
            .pro
        }
    }

    public var nextHigherRestore: MirageStreamColorDepth? {
        switch self {
        case .standard:
            .pro
        case .pro:
            .ultra
        case .ultra:
            nil
        }
    }

    package var bitDepth: MirageVideoBitDepth {
        switch self {
        case .standard:
            .eightBit
        case .pro,
             .ultra:
            .tenBit
        }
    }

    package var sortRank: Int {
        switch self {
        case .standard:
            0
        case .pro:
            1
        case .ultra:
            2
        }
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

/// Internal stream bit depth options.
package enum MirageVideoBitDepth: String, Sendable, CaseIterable, Codable {
    case eightBit = "8bit"
    case tenBit = "10bit"

    public var displayName: String {
        switch self {
        case .eightBit: "8-bit"
        case .tenBit: "10-bit"
        }
    }
}

package enum MirageStreamChromaSampling: String, Sendable, Codable, Equatable {
    case yuv420 = "4:2:0"
    case yuv422 = "4:2:2"
    case yuv444 = "4:4:4"
}

package enum MirageEncoderProfileCandidate: String, Sendable, Codable {
    case hevcMain
    case hevcMain10
    case hevcMain42210
}

package struct MirageColorDepthDescriptor: Sendable, Equatable {
    package let colorDepth: MirageStreamColorDepth
    package let bitDepth: MirageVideoBitDepth
    package let colorSpace: MirageColorSpace
    package let chromaSampling: MirageStreamChromaSampling
    package let capturePixelFormats: [MiragePixelFormat]
    package let encoderProfileCandidates: [MirageEncoderProfileCandidate]
    package let decoderPreferredPixelFormats: [MiragePixelFormat]

    package var primaryPixelFormat: MiragePixelFormat {
        capturePixelFormats[0]
    }
}

/// Color space options
package enum MirageColorSpace: String, Sendable, CaseIterable, Codable {
    case sRGB
    case displayP3 = "P3"

    public var displayName: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        }
    }
}

/// Pixel format for stream capture and encoding.
package enum MiragePixelFormat: String, Sendable, CaseIterable, Codable {
    case p010
    case bgr10a2
    case bgra8
    case nv12
    case xf44

    public var displayName: String {
        switch self {
        case .p010: "10-bit (P010)"
        case .bgr10a2: "10-bit (ARGB2101010)"
        case .bgra8: "8-bit (BGRA)"
        case .nv12: "8-bit (NV12)"
        case .xf44: "10-bit (xf44)"
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

/// Performance profile for host-side stream throughput behavior.
public enum MirageStreamPerformanceMode: String, Sendable, CaseIterable, Codable {
    case standard
    case game

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .game: "Game Mode"
        }
    }
}

/// Policy for temporary host-side degradation and recovery when a stream cannot
/// sustain its requested bitrate, frame rate, and visual settings simultaneously.
public enum MirageTemporaryDegradationMode: String, Sendable, CaseIterable, Codable {
    case off
    case prioritizeFramerate
    case prioritizeVisuals

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .prioritizeFramerate: "Prioritize Framerate"
        case .prioritizeVisuals: "Prioritize Visuals"
        }
    }
}
