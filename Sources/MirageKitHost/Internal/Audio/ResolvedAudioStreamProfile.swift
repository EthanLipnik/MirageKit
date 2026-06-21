//
//  ResolvedAudioStreamProfile.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/21/26.
//

import Foundation
import MirageKit

#if os(macOS)

struct ResolvedAudioStreamProfile: Sendable, Equatable {
    static let sampleRate = 48_000.0

    let codec: MirageAudioCodec
    let quality: MirageAudioQuality
    let sampleRate: Double
    var channelCount: Int
    var bitrateBps: Int?
    var minimumBitrateBps: Int?
    var maximumBitrateBps: Int?
    let adaptiveCompressionEnabled: Bool
    var reason: String

    var isCompressed: Bool { codec == .aacLC }

    var encodeSettings: AudioEncodeSettings {
        AudioEncodeSettings(
            codec: codec,
            sampleRate: sampleRate,
            channelCount: UInt32(max(1, channelCount)),
            bitrate: bitrateBps
        )
    }

    func withBitrate(_ bitrateBps: Int) -> ResolvedAudioStreamProfile {
        guard isCompressed else { return self }
        var profile = self
        profile.bitrateBps = AudioEncoder.roundedAACBitrate(bitrateBps)
        return profile
    }

    func withChannelCount(_ channelCount: Int, reason: String) -> ResolvedAudioStreamProfile {
        var profile = self
        profile.channelCount = max(1, channelCount)
        profile.bitrateBps = profile.bitrateBps.map {
            AudioEncoder.aacBitrate(quality: quality, channels: profile.channelCount, budgetBps: $0)
        }
        profile.minimumBitrateBps = AudioEncoder.minimumAACBitrate(channels: profile.channelCount)
        profile.maximumBitrateBps = AudioEncoder.aacBitrate(quality: quality, channels: profile.channelCount)
        profile.reason = reason
        return profile
    }

    static func resolve(
        configuration: MirageAudioConfiguration,
        transportPathKind: MirageNetworkPathKind = .unknown,
        mediaPathProfile: MirageMediaPathProfile = .unknown
    ) -> ResolvedAudioStreamProfile? {
        guard configuration.enabled else { return nil }
        let requestedChannelCount = max(1, configuration.channelLayout.channelCount)
        if configuration.quality == .lossless {
            MirageLogger.host("audio profile lossless pcm explicit")
            return ResolvedAudioStreamProfile(
                codec: .pcm16LE,
                quality: .lossless,
                sampleRate: Self.sampleRate,
                channelCount: requestedChannelCount,
                bitrateBps: nil,
                minimumBitrateBps: nil,
                maximumBitrateBps: nil,
                adaptiveCompressionEnabled: false,
                reason: "lossless-explicit"
            )
        }

        let minimum = AudioEncoder.minimumAACBitrate(channels: requestedChannelCount)
        let qualityMaximum = AudioEncoder.aacBitrate(
            quality: configuration.quality,
            channels: requestedChannelCount
        )
        let pathBudget = compressedPathBudget(
            mediaPathProfile: mediaPathProfile,
            pathKind: transportPathKind
        )
        let hostStartup = clampedBitrate(
            Int(Double(qualityMaximum) * pathBudget.startupScale),
            minimum: minimum,
            maximum: qualityMaximum
        )
        let hostMaximum = max(
            hostStartup,
            clampedBitrate(
                Int(Double(qualityMaximum) * pathBudget.maximumScale),
                minimum: minimum,
                maximum: qualityMaximum
            )
        )
        let requestedTarget = normalized(configuration.compressedBitrateBps)
        let requestedCeiling = normalized(configuration.compressedBitrateCeilingBps) ?? requestedTarget
        let maximum = max(minimum, min(hostMaximum, requestedCeiling ?? hostMaximum))
        let startup = max(minimum, min(maximum, requestedTarget.map { min(hostStartup, $0) } ?? hostStartup))

        return ResolvedAudioStreamProfile(
            codec: .aacLC,
            quality: configuration.quality,
            sampleRate: Self.sampleRate,
            channelCount: requestedChannelCount,
            bitrateBps: startup,
            minimumBitrateBps: minimum,
            maximumBitrateBps: max(startup, maximum),
            adaptiveCompressionEnabled: configuration.adaptiveCompressionEnabled,
            reason: pathBudget.label
        )
    }

    private struct PathBudget {
        let startupScale: Double
        let maximumScale: Double
        let label: String
    }

    private static func normalized(_ bitrateBps: Int?) -> Int? {
        guard let bitrateBps, bitrateBps > 0 else { return nil }
        return bitrateBps
    }

    private static func clampedBitrate(_ bitrateBps: Int, minimum: Int, maximum: Int) -> Int {
        max(minimum, min(maximum, AudioEncoder.roundedAACBitrate(bitrateBps)))
    }

    private static func compressedPathBudget(
        mediaPathProfile: MirageMediaPathProfile,
        pathKind: MirageNetworkPathKind
    ) -> PathBudget {
        switch mediaPathProfile {
        case .awdlRadio:
            PathBudget(startupScale: 0.75, maximumScale: 1.00, label: "awdl")
        case .localWiFi:
            PathBudget(startupScale: 1.00, maximumScale: 1.00, label: "wifi")
        case .wired:
            PathBudget(startupScale: 1.00, maximumScale: 1.00, label: "wired")
        case .proximityWiredLike:
            PathBudget(startupScale: 1.00, maximumScale: 1.00, label: "proximity")
        case .vpnOrOverlay:
            PathBudget(startupScale: 0.67, maximumScale: 0.85, label: "remote")
        case .other, .unknown:
            switch pathKind {
            case .wired, .loopback:
                compressedPathBudget(mediaPathProfile: .wired, pathKind: pathKind)
            case .wifi:
                compressedPathBudget(mediaPathProfile: .localWiFi, pathKind: pathKind)
            case .awdl:
                compressedPathBudget(mediaPathProfile: .awdlRadio, pathKind: pathKind)
            case .vpn, .cellular:
                compressedPathBudget(mediaPathProfile: .vpnOrOverlay, pathKind: pathKind)
            case .other, .unknown:
                PathBudget(startupScale: 0.75, maximumScale: 1.00, label: "unknown")
            }
        }
    }
}

#endif
