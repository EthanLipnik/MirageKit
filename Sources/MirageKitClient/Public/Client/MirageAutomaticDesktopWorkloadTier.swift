//
//  MirageAutomaticDesktopWorkloadTier.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//
//  Desktop workload tier values for automatic stream reconfiguration.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics

/// A desktop streaming workload level expressed as encoded pixels and target refresh rate.
public struct MirageAutomaticDesktopWorkloadTier: Sendable, Equatable {
    /// Encoded frame size after applying Mirage's even-dimension alignment.
    public let encodedPixelSize: CGSize

    /// Normalized target frame rate for this workload tier.
    public let targetFrameRate: Int

    /// Creates a workload tier from a requested encoded size and frame rate.
    public init(encodedPixelSize: CGSize, targetFrameRate: Int) {
        self.encodedPixelSize = MirageMedia.MirageStreamGeometry.alignedEncodedSize(encodedPixelSize)
        self.targetFrameRate = MirageRenderModePolicy.normalizedTargetFPS(targetFrameRate)
    }

    /// The tier's encoded pixels per second.
    public var pixelRate: Double {
        encodedPixelCount *
            Double(max(1, targetFrameRate))
    }

    /// Encoded pixels per frame after alignment and positive clamping.
    var encodedPixelCount: Double {
        Double(max(1, Int(encodedPixelSize.width))) *
            Double(max(1, Int(encodedPixelSize.height)))
    }

    /// Encoded pixels per second at a measured cadence.
    func pixelRate(at frameRate: Double) -> Double {
        encodedPixelCount * frameRate
    }

    /// Compact text used in diagnostics and workload transition logs.
    public var logLabel: String {
        "\(Int(encodedPixelSize.width))x\(Int(encodedPixelSize.height))@\(targetFrameRate)"
    }

    public static let fourK60 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 3840, height: 2160),
        targetFrameRate: 60
    )
    public static let fourK30 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 3840, height: 2160),
        targetFrameRate: 30
    )
    public static let qhd60 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 2560, height: 1440),
        targetFrameRate: 60
    )
    public static let qhd30 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 2560, height: 1440),
        targetFrameRate: 30
    )
    public static let fullHD60 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 1920, height: 1080),
        targetFrameRate: 60
    )
    public static let fullHD30 = MirageAutomaticDesktopWorkloadTier(
        encodedPixelSize: CGSize(width: 1920, height: 1080),
        targetFrameRate: 30
    )

    public static let defaultDescendingTiers: [MirageAutomaticDesktopWorkloadTier] = [
        .fourK60,
        .fourK30,
        .qhd60,
        .qhd30,
        .fullHD60,
        .fullHD30,
    ]

    /// Frame-rate ladder used when promotion can keep the current encoded resolution.
    package static let sameResolutionPromotionFrameRates = [20, 30, 60, 90, 120]
}
