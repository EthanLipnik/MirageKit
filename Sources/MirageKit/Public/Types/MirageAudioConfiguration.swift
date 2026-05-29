//
//  MirageAudioConfiguration.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation

/// Audio channel layout for streamed host audio.
public enum MirageAudioChannelLayout: String, Sendable, CaseIterable, Codable {
    /// Single-channel audio.
    case mono
    /// Two-channel left/right audio.
    case stereo
    /// 5.1 surround audio.
    case surround51

    /// Number of audio channels represented by the layout.
    public var channelCount: Int {
        switch self {
        case .mono: 1
        case .stereo: 2
        case .surround51: 6
        }
    }

    /// Display label for audio settings UI.
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
    /// Lower-bitrate audio for constrained networks.
    case low
    /// Balanced audio quality for normal streaming.
    case high
    /// Lossless audio when bandwidth and latency allow.
    case lossless

    /// Display label for audio settings UI.
    public var displayName: String {
        switch self {
        case .low: "Low"
        case .high: "High"
        case .lossless: "Lossless"
        }
    }

    /// Default compressed bitrate for this quality and channel layout.
    public func defaultCompressedBitrateBps(for channelLayout: MirageAudioChannelLayout) -> Int? {
        switch self {
        case .low:
            switch channelLayout {
            case .mono:
                64_000
            case .stereo:
                96_000
            case .surround51:
                256_000
            }
        case .high:
            switch channelLayout {
            case .mono:
                128_000
            case .stereo:
                192_000
            case .surround51:
                448_000
            }
        case .lossless:
            nil
        }
    }
}

/// Wire codec used for audio packets.
public enum MirageAudioCodec: UInt8, Sendable, Codable {
    /// AAC Low Complexity audio.
    case aacLC = 1
    /// Little-endian 16-bit PCM audio.
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
    /// Optional compressed-audio bitrate budget. Lossless audio ignores this value.
    public var compressedBitrateBps: Int?
    /// Optional upper bitrate ceiling for adaptive compressed audio. Lossless audio ignores this value.
    public var compressedBitrateCeilingBps: Int?
    /// Whether the host may adapt compressed bitrate during the active stream.
    public var adaptiveCompressionEnabled: Bool

    /// Creates an audio streaming configuration.
    public init(
        enabled: Bool = true,
        channelLayout: MirageAudioChannelLayout = .stereo,
        quality: MirageAudioQuality = .high
    ) {
        self.init(
            enabled: enabled,
            channelLayout: channelLayout,
            quality: quality,
            compressedBitrateBps: nil,
            compressedBitrateCeilingBps: nil,
            adaptiveCompressionEnabled: false
        )
    }

    /// Creates an audio streaming configuration with an explicit compressed-audio budget.
    public init(
        enabled: Bool,
        channelLayout: MirageAudioChannelLayout,
        quality: MirageAudioQuality,
        compressedBitrateBps: Int?,
        adaptiveCompressionEnabled: Bool
    ) {
        self.init(
            enabled: enabled,
            channelLayout: channelLayout,
            quality: quality,
            compressedBitrateBps: compressedBitrateBps,
            compressedBitrateCeilingBps: nil,
            adaptiveCompressionEnabled: adaptiveCompressionEnabled
        )
    }

    /// Creates an audio streaming configuration with explicit compressed-audio startup and ceiling budgets.
    public init(
        enabled: Bool,
        channelLayout: MirageAudioChannelLayout,
        quality: MirageAudioQuality,
        compressedBitrateBps: Int?,
        compressedBitrateCeilingBps: Int?,
        adaptiveCompressionEnabled: Bool
    ) {
        self.enabled = enabled
        self.channelLayout = channelLayout
        self.quality = quality
        self.compressedBitrateBps = Self.normalizedCompressedBitrateBps(
            compressedBitrateBps,
            quality: quality,
            channelLayout: channelLayout
        )
        self.compressedBitrateCeilingBps = Self.normalizedCompressedBitrateBps(
            compressedBitrateCeilingBps,
            quality: quality,
            channelLayout: channelLayout
        )
        if let compressedBitrateBps = self.compressedBitrateBps,
           let compressedBitrateCeilingBps = self.compressedBitrateCeilingBps,
           compressedBitrateCeilingBps < compressedBitrateBps {
            self.compressedBitrateCeilingBps = compressedBitrateBps
        }
        self.adaptiveCompressionEnabled = quality == .lossless ? false : adaptiveCompressionEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case channelLayout
        case quality
        case compressedBitrateBps
        case compressedBitrateCeilingBps
        case adaptiveCompressionEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        channelLayout = try container.decode(MirageAudioChannelLayout.self, forKey: .channelLayout)
        quality = try container.decode(MirageAudioQuality.self, forKey: .quality)
        let decodedBitrate = try container.decodeIfPresent(Int.self, forKey: .compressedBitrateBps)
        compressedBitrateBps = Self.normalizedCompressedBitrateBps(
            decodedBitrate,
            quality: quality,
            channelLayout: channelLayout
        )
        let decodedCeiling = try container.decodeIfPresent(Int.self, forKey: .compressedBitrateCeilingBps)
        compressedBitrateCeilingBps = Self.normalizedCompressedBitrateBps(
            decodedCeiling,
            quality: quality,
            channelLayout: channelLayout
        )
        if let compressedBitrateBps,
           let decodedCeiling = compressedBitrateCeilingBps,
           decodedCeiling < compressedBitrateBps {
            compressedBitrateCeilingBps = compressedBitrateBps
        }
        let decodedAdaptive = try container.decodeIfPresent(Bool.self, forKey: .adaptiveCompressionEnabled) ?? false
        adaptiveCompressionEnabled = quality == .lossless ? false : decodedAdaptive
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(channelLayout, forKey: .channelLayout)
        try container.encode(quality, forKey: .quality)
        try container.encodeIfPresent(compressedBitrateBps, forKey: .compressedBitrateBps)
        try container.encodeIfPresent(compressedBitrateCeilingBps, forKey: .compressedBitrateCeilingBps)
        if adaptiveCompressionEnabled {
            try container.encode(true, forKey: .adaptiveCompressionEnabled)
        }
    }

    public static let `default` = MirageAudioConfiguration()

    private static func normalizedCompressedBitrateBps(
        _ bitrateBps: Int?,
        quality: MirageAudioQuality,
        channelLayout: MirageAudioChannelLayout
    ) -> Int? {
        guard quality != .lossless, let bitrateBps else { return nil }
        let minimum = switch channelLayout {
        case .mono:
            40_000
        case .stereo:
            64_000
        case .surround51:
            160_000
        }
        return max(minimum, bitrateBps)
    }

    /// Resolves host-audio policy for a desktop stream mode.
    /// Secondary display streams are video-only because host audio belongs to
    /// unified desktop and app/window streaming, not the synthetic display.
    public func resolvedForDesktopStreamMode(_ mode: MirageDesktopStreamMode) -> MirageAudioConfiguration {
        guard mode == .secondary, enabled else { return self }
        var configuration = self
        configuration.enabled = false
        return configuration
    }
}
