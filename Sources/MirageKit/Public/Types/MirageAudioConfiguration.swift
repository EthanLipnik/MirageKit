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

    /// Creates an audio streaming configuration.
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
