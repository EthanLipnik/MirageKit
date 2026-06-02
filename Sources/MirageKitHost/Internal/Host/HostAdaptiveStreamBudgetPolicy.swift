//
//  HostAdaptiveStreamBudgetPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
struct HostAdaptiveStreamBudgetPolicy: Equatable {
    struct Request: Equatable {
        let requestedBitrateBps: Int?
        let requestedCeilingBps: Int?
        let enteredBitrateBps: Int?
        let runtimeQualityAdjustmentEnabled: Bool
        let encoderCatchUpQualityAdjustmentEnabled: Bool
        let codec: MirageVideoCodec
        let outputSize: CGSize
        let frameRate: Int
        let transportPathKind: MirageNetworkPathKind
        let mediaPathProfile: MirageMediaPathProfile
    }

    struct Decision: Equatable {
        let startupBitrateBps: Int
        let maximumCeilingBps: Int
        let minimumBitrateFloorBps: Int
        let encoderThroughputMinimumBitrateFloorBps: Int
        let reason: String
    }

    private struct PathBudget: Equatable {
        let startupBitsPerPixelPerFrame: Double
        let maximumBitsPerPixelPerFrame: Double
        let startupCapBps: Int
        let maximumCapBps: Int
        let minimumFloorBps: Int
        let honorsRequestedStartup: Bool
        let label: String
    }

    private static let fallbackMinimumFloorBps = 4_000_000
    private static let highResolutionManualStartupPixels = 10_500_000.0
    private static let highResolutionManualFloorFraction = 0.60

    static func resolve(_ request: Request) -> Decision? {
        guard request.runtimeQualityAdjustmentEnabled else { return nil }
        guard request.codec != .proRes4444 else { return nil }
        guard request.outputSize.width > 0,
              request.outputSize.height > 0,
              request.frameRate > 0 else {
            return nil
        }

        let pathBudget = budget(for: request.mediaPathProfile, pathKind: request.transportPathKind)
        let geometryStartup = bitrate(
            outputSize: request.outputSize,
            frameRate: request.frameRate,
            bitsPerPixelPerFrame: pathBudget.startupBitsPerPixelPerFrame
        )
        let geometryMaximum = bitrate(
            outputSize: request.outputSize,
            frameRate: request.frameRate,
            bitsPerPixelPerFrame: pathBudget.maximumBitsPerPixelPerFrame
        )
        let hostStartup = max(1, min(pathBudget.startupCapBps, geometryStartup))
        let hostMaximum = max(hostStartup, min(pathBudget.maximumCapBps, geometryMaximum))

        let requestedTarget = normalized(request.requestedBitrateBps)
        let clientCeiling = clientMaximumCeiling(
            enteredBitrateBps: request.enteredBitrateBps,
            requestedCeilingBps: request.requestedCeilingBps
        )
        let maximumCeiling = max(
            1,
            min(hostMaximum, clientCeiling ?? hostMaximum)
        )

        let explicitStartup = normalized(request.enteredBitrateBps)
        let manualFloor = request.requestedCeilingBps == nil ? manualMinimumFloorBitrate(
            explicitStartup: explicitStartup,
            maximumCeiling: maximumCeiling,
            outputSize: request.outputSize
        ) : nil
        let clientStartupLimited = if let explicitStartup {
            manualStartupBitrate(
                explicitStartup: explicitStartup,
                hostStartup: hostStartup,
                outputSize: request.outputSize,
                pathBudget: pathBudget
            )
        } else if let requestedTarget, pathBudget.honorsRequestedStartup {
            min(hostStartup, requestedTarget)
        } else if let requestedTarget {
            min(hostStartup, requestedTarget)
        } else {
            hostStartup
        }
        var startupBitrate = min(maximumCeiling, max(manualFloor ?? 1, clientStartupLimited))
        if let requestedTarget, explicitStartup == nil, requestedTarget > hostStartup {
            startupBitrate = min(maximumCeiling, hostStartup)
        } else if let requestedTarget, !pathBudget.honorsRequestedStartup, requestedTarget > hostStartup {
            startupBitrate = min(maximumCeiling, hostStartup)
        }

        let minimumFloor = min(
            max(1, maximumCeiling),
            max(1, pathBudget.minimumFloorBps, manualFloor ?? 0)
        )
        let encoderThroughputMinimumFloor = if request.encoderCatchUpQualityAdjustmentEnabled {
            min(
                max(1, maximumCeiling),
                max(1, pathBudget.minimumFloorBps)
            )
        } else {
            minimumFloor
        }
        let boundedCeiling = max(startupBitrate, maximumCeiling, minimumFloor)
        let reason = pathBudget.label

        return Decision(
            startupBitrateBps: startupBitrate,
            maximumCeilingBps: boundedCeiling,
            minimumBitrateFloorBps: minimumFloor,
            encoderThroughputMinimumBitrateFloorBps: encoderThroughputMinimumFloor,
            reason: reason
        )
    }

    private static func normalized(_ bitrate: Int?) -> Int? {
        guard let bitrate, bitrate > 0 else { return nil }
        return bitrate
    }

    private static func manualStartupBitrate(
        explicitStartup: Int,
        hostStartup: Int,
        outputSize: CGSize,
        pathBudget: PathBudget
    ) -> Int {
        guard pathBudget.honorsRequestedStartup else {
            return min(explicitStartup, hostStartup)
        }
        let pixelCount = max(0, outputSize.width) * max(0, outputSize.height)
        guard pixelCount >= highResolutionManualStartupPixels,
              explicitStartup > hostStartup else {
            return explicitStartup
        }
        return hostStartup
    }

    private static func manualMinimumFloorBitrate(
        explicitStartup: Int?,
        maximumCeiling: Int,
        outputSize: CGSize
    ) -> Int? {
        guard let explicitStartup else { return nil }
        let pixelCount = max(0, outputSize.width) * max(0, outputSize.height)
        guard pixelCount >= highResolutionManualStartupPixels else { return nil }
        let floor = Int((Double(explicitStartup) * highResolutionManualFloorFraction).rounded(.down))
        return min(maximumCeiling, max(1, floor))
    }

    private static func clientMaximumCeiling(
        enteredBitrateBps: Int?,
        requestedCeilingBps: Int?
    ) -> Int? {
        let enteredBitrate = normalized(enteredBitrateBps)
        let requestedCeiling = normalized(requestedCeilingBps)
        if enteredBitrate != nil || requestedCeiling != nil {
            return [enteredBitrate, requestedCeiling]
                .compactMap { $0 }
                .min()
        }
        return nil
    }

    private static func bitrate(
        outputSize: CGSize,
        frameRate: Int,
        bitsPerPixelPerFrame: Double
    ) -> Int {
        let width = max(2.0, floor(Double(outputSize.width) / 2.0) * 2.0)
        let height = max(2.0, floor(Double(outputSize.height) / 2.0) * 2.0)
        let bitrate = width * height * Double(max(1, frameRate)) * bitsPerPixelPerFrame
        return max(1, Int(bitrate.rounded(.toNearestOrAwayFromZero)))
    }

    private static func budget(
        for mediaPathProfile: MirageMediaPathProfile,
        pathKind: MirageNetworkPathKind
    ) -> PathBudget {
        switch mediaPathProfile {
        case .awdlRadio:
            return PathBudget(
                startupBitsPerPixelPerFrame: 0.075,
                maximumBitsPerPixelPerFrame: 0.280,
                startupCapBps: 32_000_000,
                maximumCapBps: 120_000_000,
                minimumFloorBps: 18_000_000,
                honorsRequestedStartup: false,
                label: "awdlInteractiveDisplay"
            )
        case .localWiFi:
            return PathBudget(
                startupBitsPerPixelPerFrame: 0.095,
                maximumBitsPerPixelPerFrame: 0.530,
                startupCapBps: 36_000_000,
                maximumCapBps: 180_000_000,
                minimumFloorBps: 3_000_000,
                honorsRequestedStartup: true,
                label: "wifi"
            )
        case .wired:
            return PathBudget(
                startupBitsPerPixelPerFrame: 0.140,
                maximumBitsPerPixelPerFrame: 0.450,
                startupCapBps: 72_000_000,
                maximumCapBps: 180_000_000,
                minimumFloorBps: 8_000_000,
                honorsRequestedStartup: true,
                label: "wired"
            )
        case .proximityWiredLike:
            return PathBudget(
                startupBitsPerPixelPerFrame: 0.220,
                maximumBitsPerPixelPerFrame: 0.650,
                startupCapBps: 140_000_000,
                maximumCapBps: 300_000_000,
                minimumFloorBps: 12_000_000,
                honorsRequestedStartup: true,
                label: "proximity"
            )
        case .vpnOrOverlay:
            return PathBudget(
                startupBitsPerPixelPerFrame: 0.200,
                maximumBitsPerPixelPerFrame: 0.450,
                startupCapBps: 96_000_000,
                maximumCapBps: 180_000_000,
                minimumFloorBps: 8_000_000,
                honorsRequestedStartup: true,
                label: "remote"
            )
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
                return PathBudget(
                    startupBitsPerPixelPerFrame: 0.060,
                    maximumBitsPerPixelPerFrame: 0.120,
                    startupCapBps: 18_000_000,
                    maximumCapBps: 48_000_000,
                    minimumFloorBps: fallbackMinimumFloorBps,
                    honorsRequestedStartup: false,
                    label: "unknown"
                )
            }
        }
    }
}
#endif
