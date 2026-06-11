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
        let encoderStartupBitrateBps: Int
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
        let honorsAutomaticClientStartup: Bool
        let honorsAutomaticClientCeiling: Bool
        let minimumAutomaticClientCeilingBps: Int?
        let label: String
    }

    private static let fallbackMinimumFloorBps = 4_000_000
    private static let highResolutionManualStartupPixels = 10_500_000.0
    private static let highResolutionManualFloorFraction = 0.60
    private static let awdlStartupReadabilityFrameQuality: Float = 0.28
    private static let awdlStartupReadabilityCapBps = 72_000_000
    private static let automaticStartupReadabilityFrameQuality: Float = 0.60
    private static let optimizedVPNAutomaticStartupReadabilityFrameQuality: Float = 0.75
    private static let proximityAutomaticStartupReadabilityFrameQuality: Float = 0.65

    static func resolve(_ request: Request) -> Decision? {
        guard request.codec != .proRes4444 else { return nil }
        guard request.outputSize.width > 0,
              request.outputSize.height > 0,
              request.frameRate > 0 else {
            return nil
        }

        let usesOptimizedVPNProfile = usesOptimizedVPNProfile(request)
        let pathBudget = budget(
            for: request.mediaPathProfile,
            pathKind: request.transportPathKind,
            usesOptimizedVPNProfile: usesOptimizedVPNProfile
        )
        let usesAwdlInteractiveBudget = pathBudget.label == "awdlInteractiveDisplay"
        guard request.runtimeQualityAdjustmentEnabled || usesAwdlInteractiveBudget else { return nil }
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
        let automaticRequestedTarget = pathBudget.honorsAutomaticClientStartup
            ? requestedTarget
            : nil
        let requestedCeiling = filteredRequestedCeiling(
            request.requestedCeilingBps,
            enteredBitrateBps: request.enteredBitrateBps,
            pathBudget: pathBudget
        )
        let clientCeiling = readabilityProtectedClientCeiling(
            enteredBitrateBps: request.enteredBitrateBps,
            requestedCeilingBps: requestedCeiling,
            pathBudget: pathBudget,
            usesAwdlInteractiveBudget: usesAwdlInteractiveBudget
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
        let automaticReadabilityFloor = automaticStartupReadabilityFloor(
            request: request,
            maximumCeiling: maximumCeiling,
            usesOptimizedVPNProfile: usesOptimizedVPNProfile
        )
        let clientStartupLimited = if let explicitStartup {
            manualStartupBitrate(
                explicitStartup: explicitStartup,
                hostStartup: hostStartup,
                outputSize: request.outputSize,
                pathBudget: pathBudget
            )
        } else if let automaticRequestedTarget, pathBudget.honorsRequestedStartup {
            min(hostStartup, automaticRequestedTarget)
        } else if let automaticRequestedTarget {
            min(hostStartup, automaticRequestedTarget)
        } else {
            hostStartup
        }
        var startupBitrate = min(
            maximumCeiling,
            max(manualFloor ?? 1, automaticReadabilityFloor ?? 1, clientStartupLimited)
        )
        if usesAwdlInteractiveBudget {
            startupBitrate = max(
                startupBitrate,
                min(maximumCeiling, pathBudget.minimumFloorBps)
            )
        }
        let automaticHostStartupLimit = max(hostStartup, automaticReadabilityFloor ?? hostStartup)
        if let automaticRequestedTarget, explicitStartup == nil, automaticRequestedTarget > hostStartup {
            startupBitrate = min(maximumCeiling, automaticHostStartupLimit)
        } else if let automaticRequestedTarget,
                  !pathBudget.honorsRequestedStartup,
                  automaticRequestedTarget > hostStartup {
            startupBitrate = min(maximumCeiling, automaticHostStartupLimit)
        }

        let minimumFloor = min(
            max(1, maximumCeiling),
            max(1, pathBudget.minimumFloorBps, manualFloor ?? 0, automaticReadabilityFloor ?? 0)
        )
        let encoderThroughputMinimumFloor = if request.encoderCatchUpQualityAdjustmentEnabled {
            min(
                max(1, maximumCeiling),
                max(1, pathBudget.minimumFloorBps, automaticReadabilityFloor ?? 0)
            )
        } else {
            minimumFloor
        }
        let boundedCeiling = max(startupBitrate, maximumCeiling, minimumFloor)
        let reason = pathBudget.label
        let encoderStartupBitrate = encoderStartupBitrate(
            startupBitrate: startupBitrate,
            encoderCeilingBps: boundedCeiling,
            request: request,
            usesAwdlInteractiveBudget: usesAwdlInteractiveBudget
        )

        return Decision(
            startupBitrateBps: startupBitrate,
            encoderStartupBitrateBps: encoderStartupBitrate,
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

    private static func automaticStartupReadabilityFloor(
        request: Request,
        maximumCeiling: Int,
        usesOptimizedVPNProfile: Bool
    ) -> Int? {
        guard request.enteredBitrateBps == nil,
              let readabilityFrameQuality = automaticStartupReadabilityFrameQuality(
                  for: request.mediaPathProfile,
                  usesOptimizedVPNProfile: usesOptimizedVPNProfile
              ) else {
            return nil
        }
        let width = max(2, Int(request.outputSize.width))
        let height = max(2, Int(request.outputSize.height))
        guard let readabilityBitrate = MirageBitrateQualityMapper.targetBitrateBps(
            forFrameQuality: readabilityFrameQuality,
            width: width,
            height: height,
            frameRate: request.frameRate,
            maxBitrateBps: maximumCeiling
        ) else {
            return maximumCeiling
        }
        return min(maximumCeiling, max(1, readabilityBitrate))
    }

    private static func automaticStartupReadabilityFrameQuality(
        for mediaPathProfile: MirageMediaPathProfile,
        usesOptimizedVPNProfile: Bool
    ) -> Float? {
        switch mediaPathProfile {
        case .localWiFi,
             .wired:
            return Self.automaticStartupReadabilityFrameQuality
        case .vpnOrOverlay:
            return usesOptimizedVPNProfile
                ? Self.optimizedVPNAutomaticStartupReadabilityFrameQuality
                : Self.automaticStartupReadabilityFrameQuality
        case .proximityWiredLike:
            return proximityAutomaticStartupReadabilityFrameQuality
        case .awdlRadio,
             .other,
             .unknown:
            return nil
        }
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

    private static func readabilityProtectedClientCeiling(
        enteredBitrateBps: Int?,
        requestedCeilingBps: Int?,
        pathBudget: PathBudget,
        usesAwdlInteractiveBudget: Bool
    ) -> Int? {
        guard let ceiling = clientMaximumCeiling(
            enteredBitrateBps: enteredBitrateBps,
            requestedCeilingBps: requestedCeilingBps
        ) else {
            return nil
        }
        guard usesAwdlInteractiveBudget else { return ceiling }
        return max(ceiling, pathBudget.minimumFloorBps)
    }

    private static func filteredRequestedCeiling(
        _ requestedCeilingBps: Int?,
        enteredBitrateBps: Int?,
        pathBudget: PathBudget
    ) -> Int? {
        guard pathBudget.honorsAutomaticClientCeiling else { return nil }
        guard let requestedCeiling = normalized(requestedCeilingBps) else { return nil }
        guard enteredBitrateBps == nil,
              let minimumAutomaticClientCeilingBps = pathBudget.minimumAutomaticClientCeilingBps else {
            return requestedCeiling
        }
        return requestedCeiling >= minimumAutomaticClientCeilingBps ? requestedCeiling : nil
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

    private static func encoderStartupBitrate(
        startupBitrate: Int,
        encoderCeilingBps: Int,
        request: Request,
        usesAwdlInteractiveBudget: Bool
    ) -> Int {
        guard usesAwdlInteractiveBudget,
              request.enteredBitrateBps == nil else {
            return startupBitrate
        }
        let width = max(2, Int(request.outputSize.width))
        let height = max(2, Int(request.outputSize.height))
        guard let readabilityBitrate = MirageBitrateQualityMapper.targetBitrateBps(
            forFrameQuality: awdlStartupReadabilityFrameQuality,
            width: width,
            height: height,
            frameRate: request.frameRate,
            maxBitrateBps: awdlStartupReadabilityCapBps
        ) else {
            return startupBitrate
        }
        return min(encoderCeilingBps, max(startupBitrate, readabilityBitrate))
    }

    private static func budget(
        for mediaPathProfile: MirageMediaPathProfile,
        pathKind: MirageNetworkPathKind,
        usesOptimizedVPNProfile: Bool = false
    ) -> PathBudget {
        switch mediaPathProfile {
        case .awdlRadio:
            return PathBudget(
                startupBitsPerPixelPerFrame: 0.075,
                maximumBitsPerPixelPerFrame: 0.280,
                startupCapBps: 32_000_000,
                maximumCapBps: 32_000_000,
                minimumFloorBps: 18_000_000,
                honorsRequestedStartup: false,
                honorsAutomaticClientStartup: false,
                honorsAutomaticClientCeiling: true,
                minimumAutomaticClientCeilingBps: 32_000_000,
                label: "awdlInteractiveDisplay"
            )
        case .localWiFi:
            return PathBudget(
                startupBitsPerPixelPerFrame: 0.095,
                maximumBitsPerPixelPerFrame: 0.900,
                startupCapBps: 36_000_000,
                maximumCapBps: 300_000_000,
                minimumFloorBps: 3_000_000,
                honorsRequestedStartup: true,
                honorsAutomaticClientStartup: true,
                honorsAutomaticClientCeiling: true,
                minimumAutomaticClientCeilingBps: 300_000_000,
                label: "wifi"
            )
        case .wired:
            return PathBudget(
                startupBitsPerPixelPerFrame: 0.140,
                maximumBitsPerPixelPerFrame: 0.900,
                startupCapBps: 72_000_000,
                maximumCapBps: 300_000_000,
                minimumFloorBps: 8_000_000,
                honorsRequestedStartup: true,
                honorsAutomaticClientStartup: true,
                honorsAutomaticClientCeiling: true,
                minimumAutomaticClientCeilingBps: 300_000_000,
                label: "wired"
            )
        case .proximityWiredLike:
            return PathBudget(
                startupBitsPerPixelPerFrame: 0.220,
                maximumBitsPerPixelPerFrame: 0.900,
                startupCapBps: 140_000_000,
                maximumCapBps: 300_000_000,
                minimumFloorBps: 12_000_000,
                honorsRequestedStartup: true,
                honorsAutomaticClientStartup: true,
                honorsAutomaticClientCeiling: true,
                minimumAutomaticClientCeilingBps: 300_000_000,
                label: "proximity"
            )
        case .vpnOrOverlay:
            guard usesOptimizedVPNProfile else {
                return PathBudget(
                    startupBitsPerPixelPerFrame: 0.200,
                    maximumBitsPerPixelPerFrame: 0.450,
                    startupCapBps: 96_000_000,
                    maximumCapBps: 180_000_000,
                    minimumFloorBps: 8_000_000,
                    honorsRequestedStartup: true,
                    honorsAutomaticClientStartup: true,
                    honorsAutomaticClientCeiling: true,
                    minimumAutomaticClientCeilingBps: nil,
                    label: "remote"
                )
            }
            return PathBudget(
                startupBitsPerPixelPerFrame: 0.385,
                maximumBitsPerPixelPerFrame: 0.800,
                startupCapBps: 96_000_000,
                maximumCapBps: 120_000_000,
                minimumFloorBps: 8_000_000,
                honorsRequestedStartup: true,
                honorsAutomaticClientStartup: true,
                honorsAutomaticClientCeiling: true,
                minimumAutomaticClientCeilingBps: nil,
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
                return budget(
                    for: .vpnOrOverlay,
                    pathKind: pathKind,
                    usesOptimizedVPNProfile: usesOptimizedVPNProfile
                )
            case .other, .unknown:
                return PathBudget(
                    startupBitsPerPixelPerFrame: 0.060,
                    maximumBitsPerPixelPerFrame: 0.120,
                    startupCapBps: 18_000_000,
                    maximumCapBps: 48_000_000,
                    minimumFloorBps: fallbackMinimumFloorBps,
                    honorsRequestedStartup: false,
                    honorsAutomaticClientStartup: true,
                    honorsAutomaticClientCeiling: true,
                    minimumAutomaticClientCeilingBps: nil,
                    label: "unknown"
                )
            }
        }
    }

    private static func usesOptimizedVPNProfile(_ request: Request) -> Bool {
        guard request.mediaPathProfile == .vpnOrOverlay,
              request.transportPathKind == .vpn,
              request.enteredBitrateBps == nil,
              request.frameRate == 30,
              let requestedBitrate = normalized(request.requestedBitrateBps),
              Self.optimizedVPNProfileStartupBitratesBps.contains(requestedBitrate),
              let requestedCeiling = normalized(request.requestedCeilingBps),
              requestedCeiling >= requestedBitrate else {
            return false
        }
        return true
    }

    private static let optimizedVPNProfileStartupBitratesBps: Set<Int> = [
        24_000_000,
        30_000_000,
        36_000_000,
    ]
}
#endif
