//
//  HostAdaptiveAudioBudgetPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

import Foundation
import MirageKit

#if os(macOS)

struct HostAdaptiveAudioBudgetPolicy: Equatable {
    struct Request: Equatable {
        let configuration: MirageAudioConfiguration
        let transportPathKind: MirageNetworkPathKind
        let mediaPathProfile: MirageMediaPathProfile
    }

    struct Decision: Equatable {
        let startupBitrateBps: Int
        let maximumCeilingBps: Int
        let minimumBitrateFloorBps: Int
        let reason: String
    }

    private struct PathBudget: Equatable {
        let startupScale: Double
        let maximumScale: Double
        let label: String
    }

    static func resolve(_ request: Request) -> Decision? {
        let configuration = request.configuration
        guard configuration.enabled,
              configuration.quality != .lossless,
              configuration.adaptiveCompressionEnabled else {
            return nil
        }

        let channelCount = configuration.channelLayout.channelCount
        let floor = AudioEncoder.minimumAACBitrate(channels: channelCount)
        let qualityMaximum = AudioEncoder.aacBitrate(
            quality: configuration.quality,
            channels: channelCount
        )
        let pathBudget = budget(for: request.mediaPathProfile, pathKind: request.transportPathKind)
        let hostStartup = clampedBitrate(
            Int(Double(qualityMaximum) * pathBudget.startupScale),
            minimum: floor,
            maximum: qualityMaximum
        )
        let hostMaximum = max(
            hostStartup,
            clampedBitrate(
                Int(Double(qualityMaximum) * pathBudget.maximumScale),
                minimum: floor,
                maximum: qualityMaximum
            )
        )

        let requestedTarget = normalized(configuration.compressedBitrateBps)
        let clientCeiling = normalized(configuration.compressedBitrateCeilingBps) ?? requestedTarget
        let maximumCeiling = max(
            floor,
            min(hostMaximum, clientCeiling ?? hostMaximum)
        )
        let startupLimitedByClient = requestedTarget.map { min(hostStartup, $0) } ?? hostStartup
        let startupBitrate = max(floor, min(maximumCeiling, startupLimitedByClient))

        return Decision(
            startupBitrateBps: startupBitrate,
            maximumCeilingBps: max(startupBitrate, maximumCeiling),
            minimumBitrateFloorBps: min(startupBitrate, floor),
            reason: pathBudget.label
        )
    }

    private static func normalized(_ bitrateBps: Int?) -> Int? {
        guard let bitrateBps, bitrateBps > 0 else { return nil }
        return bitrateBps
    }

    private static func clampedBitrate(
        _ bitrateBps: Int,
        minimum: Int,
        maximum: Int
    ) -> Int {
        max(minimum, min(maximum, AudioEncoder.roundedAACBitrate(bitrateBps)))
    }

    private static func budget(
        for mediaPathProfile: MirageMediaPathProfile,
        pathKind: MirageNetworkPathKind
    ) -> PathBudget {
        switch mediaPathProfile {
        case .awdlRadio:
            return PathBudget(startupScale: 0.75, maximumScale: 1.00, label: "awdl")
        case .localWiFi:
            return PathBudget(startupScale: 1.00, maximumScale: 1.00, label: "wifi")
        case .wired:
            return PathBudget(startupScale: 1.00, maximumScale: 1.00, label: "wired")
        case .proximityWiredLike:
            return PathBudget(startupScale: 1.00, maximumScale: 1.00, label: "proximity")
        case .vpnOrOverlay:
            return PathBudget(startupScale: 0.67, maximumScale: 0.85, label: "remote")
        case .other,
             .unknown:
            switch pathKind {
            case .wired, .loopback:
                return budget(for: .wired, pathKind: pathKind)
            case .wifi:
                return budget(for: .localWiFi, pathKind: pathKind)
            case .awdl:
                return budget(for: .awdlRadio, pathKind: pathKind)
            case .vpn, .cellular:
                return budget(for: .vpnOrOverlay, pathKind: pathKind)
            case .other, .unknown:
                return PathBudget(startupScale: 0.75, maximumScale: 1.00, label: "unknown")
            }
        }
    }
}

#endif
