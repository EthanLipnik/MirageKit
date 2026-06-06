//
//  Configuration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation

// MARK: - Encoder Configuration

/// Configuration for video encoding on the host.
public struct MirageEncoderConfiguration: Sendable {
    /// Video codec to use
    public var codec: MirageMedia.MirageVideoCodec

    /// Target frame rate
    public var targetFrameRate: Int

    /// Keyframe interval (in frames)
    public var keyFrameInterval: Int

    /// User-selected stream color depth preset.
    public var colorDepth: MirageMedia.MirageStreamColorDepth

    /// Internal derived stream bit depth.
    package var bitDepth: MirageMedia.MirageVideoBitDepth

    /// Color space for encoding.
    package var colorSpace: MirageMedia.MirageColorSpace

    /// Scale factor for retina displays
    public var scaleFactor: CGFloat

    /// Pixel format for capture and encode.
    package var pixelFormat: MirageMedia.MiragePixelFormat
    /// Capture queue depth override for ScreenCaptureKit (nil uses adaptive defaults)
    public var captureQueueDepth: Int?

    /// Target bitrate in bits per second
    public var bitrate: Int?

    /// Internal derived quality levels used by the encoder.
    package var frameQuality: Float
    package var keyframeQuality: Float

    /// Creates an encoder configuration and derives pixel format/color settings from the selected color depth.
    public init(
        codec: MirageMedia.MirageVideoCodec = .hevc,
        targetFrameRate: Int = 60,
        keyFrameInterval: Int = 1800,
        colorDepth: MirageMedia.MirageStreamColorDepth = .standard,
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
        codec: MirageMedia.MirageVideoCodec = .hevc,
        targetFrameRate: Int = 60,
        keyFrameInterval: Int = 1800,
        colorDepth: MirageMedia.MirageStreamColorDepth,
        colorSpace: MirageMedia.MirageColorSpace,
        scaleFactor: CGFloat = 2.0,
        pixelFormat: MirageMedia.MiragePixelFormat,
        captureQueueDepth: Int? = nil,
        bitrate: Int? = nil
    ) {
        self.codec = codec
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.colorDepth = colorDepth
        bitDepth = Self.bitDepth(for: pixelFormat)
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
        colorDepth: MirageMedia.MirageStreamColorDepth? = nil,
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
        pixelFormat: MirageMedia.MiragePixelFormat? = nil,
        colorSpace: MirageMedia.MirageColorSpace? = nil,
        bitDepth: MirageMedia.MirageVideoBitDepth? = nil,
        colorDepth: MirageMedia.MirageStreamColorDepth? = nil,
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

    package mutating func apply(colorDepth: MirageMedia.MirageStreamColorDepth) {
        let descriptor = Self.descriptor(for: colorDepth)
        self.colorDepth = colorDepth
        bitDepth = descriptor.bitDepth
        colorSpace = descriptor.colorSpace
        pixelFormat = descriptor.primaryPixelFormat
    }

    /// Apply BGRA pixel format override for MetalFX upscaling while preserving
    /// the current color depth and color space. The BGRA variant is always the
    /// second entry in the descriptor's capture format list.
    package mutating func applyUpscalingPixelFormat() {
        let descriptor = Self.descriptor(for: colorDepth)
        if let bgraFormat = descriptor.capturePixelFormats.first(where: {
            $0 == .bgra8 || $0 == .bgr10a2
        }) {
            pixelFormat = bgraFormat
        }
    }

    package static func descriptor(for colorDepth: MirageMedia.MirageStreamColorDepth) -> MirageMedia.MirageColorDepthDescriptor {
        switch colorDepth {
        case .standard:
            MirageMedia.MirageColorDepthDescriptor(
                colorDepth: .standard,
                bitDepth: .eightBit,
                colorSpace: .sRGB,
                capturePixelFormats: [.nv12, .bgra8]
            )
        case .pro:
            MirageMedia.MirageColorDepthDescriptor(
                colorDepth: .pro,
                bitDepth: .tenBit,
                colorSpace: .displayP3,
                capturePixelFormats: [.p010, .bgr10a2]
            )
        case .ultra:
            MirageMedia.MirageColorDepthDescriptor(
                colorDepth: .ultra,
                bitDepth: .tenBit,
                colorSpace: .displayP3,
                capturePixelFormats: [.xf44, .p010, .bgr10a2]
            )
        }
    }

    package static func descriptor(for pixelFormat: MirageMedia.MiragePixelFormat) -> MirageMedia.MirageColorDepthDescriptor {
        switch pixelFormat {
        case .xf44,
             .ayuv16:
            descriptor(for: .ultra)
        case .p010,
             .bgr10a2:
            descriptor(for: .pro)
        case .bgra8,
             .nv12:
            descriptor(for: .standard)
        }
    }

    package static func pixelFormat(for bitDepth: MirageMedia.MirageVideoBitDepth) -> MirageMedia.MiragePixelFormat {
        switch bitDepth {
        case .eightBit: .nv12
        case .tenBit: .p010
        }
    }

    package static func colorSpace(for bitDepth: MirageMedia.MirageVideoBitDepth) -> MirageMedia.MirageColorSpace {
        switch bitDepth {
        case .eightBit: .sRGB
        case .tenBit: .displayP3
        }
    }

    package static func bitDepth(for pixelFormat: MirageMedia.MiragePixelFormat) -> MirageMedia.MirageVideoBitDepth {
        switch pixelFormat {
        case .p010, .bgr10a2, .xf44, .ayuv16:
            .tenBit
        case .bgra8, .nv12:
            .eightBit
        }
    }

    package static func defaultColorDepth(for bitDepth: MirageMedia.MirageVideoBitDepth) -> MirageMedia.MirageStreamColorDepth {
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
public struct MirageEncoderOverrides: Sendable, Codable, Equatable {
    /// Preferred video codec.
    public var codec: MirageMedia.MirageVideoCodec?
    /// Preferred keyframe interval in frames.
    public var keyFrameInterval: Int?
    /// Preferred stream color depth preset.
    public var colorDepth: MirageMedia.MirageStreamColorDepth?
    /// Capture queue depth requested for the stream.
    public var captureQueueDepth: Int?
    /// Client-entered bitrate budget before any desktop geometry scaling.
    /// For custom desktop streaming this remains the user-facing value shown in
    /// settings, while `bitrate` carries the effective target actually sent to
    /// the host.
    public var enteredBitrate: Int?
    /// Effective target bitrate sent to the host.
    public var bitrate: Int?
    /// Preferred latency policy for the stream.
    public var latencyMode: MirageMedia.MirageStreamLatencyMode?
    /// Preferred host-side capture-to-encode buffering policy.
    public var hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy?
    /// Preferred host-side capture and encode buffer depth.
    public var hostBufferDepth: MirageMedia.MirageHostBufferDepth?
    /// Whether the host may adjust quality while the stream is running.
    public var allowRuntimeQualityAdjustment: Bool?
    /// Whether the host may temporarily lower quality when encoding falls behind.
    public var allowEncoderCatchUpQualityAdjustment: Bool?
    /// Legacy compatibility field. Current hosts ignore this value.
    public var lowLatencyHighResolutionCompressionBoost: Bool?
    /// Whether the host should ignore normal resolution caps for this stream.
    public var disableResolutionCap: Bool
    /// Maximum bitrate budget the host-side adaptation loop may use for this stream.
    public var bitrateAdaptationCeiling: Int?
    /// Maximum encoded width in pixels. When set, the host computes the stream
    /// scale from these dimensions and the actual capture resolution instead of
    /// using the client-provided stream scale for virtual display sizing.
    public var encoderMaxWidth: Int?
    /// Maximum encoded height in pixels.
    public var encoderMaxHeight: Int?
    /// Client-requested MetalFX upscaling mode.
    public var upscalingMode: MirageMedia.MirageUpscalingMode?
    /// Maximum host encoder compression-quality value for this stream.
    public var compressionQualityCeiling: Float?

    /// Creates a partial encoder override payload for runtime or stream-start updates.
    public init(
        codec: MirageMedia.MirageVideoCodec? = nil,
        keyFrameInterval: Int? = nil,
        colorDepth: MirageMedia.MirageStreamColorDepth? = nil,
        captureQueueDepth: Int? = nil,
        enteredBitrate: Int? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageMedia.MirageStreamLatencyMode? = nil,
        hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy? = nil,
        hostBufferDepth: MirageMedia.MirageHostBufferDepth? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        allowEncoderCatchUpQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        disableResolutionCap: Bool = false,
        bitrateAdaptationCeiling: Int? = nil,
        encoderMaxWidth: Int? = nil,
        encoderMaxHeight: Int? = nil,
        upscalingMode: MirageMedia.MirageUpscalingMode? = nil,
        compressionQualityCeiling: Float? = nil
    ) {
        self.codec = codec
        self.keyFrameInterval = keyFrameInterval
        self.colorDepth = colorDepth
        self.captureQueueDepth = captureQueueDepth
        self.enteredBitrate = enteredBitrate
        self.bitrate = bitrate
        self.latencyMode = latencyMode
        self.hostBufferingPolicy = hostBufferingPolicy
        self.hostBufferDepth = hostBufferDepth
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.allowEncoderCatchUpQualityAdjustment = allowEncoderCatchUpQualityAdjustment
        self.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        self.disableResolutionCap = disableResolutionCap
        self.bitrateAdaptationCeiling = bitrateAdaptationCeiling
        self.encoderMaxWidth = encoderMaxWidth
        self.encoderMaxHeight = encoderMaxHeight
        self.upscalingMode = upscalingMode
        self.compressionQualityCeiling = compressionQualityCeiling
    }
}
