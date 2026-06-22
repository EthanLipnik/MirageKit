//
//  StreamContext+Init.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Sizing helpers for stream context.
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
import CoreVideo
import Foundation

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    /// Clamps host stream scaling to the supported encoded-size multiplier range.
    static func clampStreamScale(_ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 1.0 }
        return max(0.1, min(1.0, scale))
    }

    func resolvedStreamScale(
        for baseSize: CGSize,
        requestedScale: CGFloat,
        logLabel: String?
    )
    -> CGFloat {
        let effectiveEncoderMaxWidth = disableResolutionCap
            ? nil
            : encoderMaxWidth ?? Int(Self.maxEncodedWidth)
        let effectiveEncoderMaxHeight = disableResolutionCap
            ? nil
            : encoderMaxHeight ?? Int(Self.maxEncodedHeight)
        let plan = MirageMedia.MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: baseSize,
            requestedStreamScale: requestedScale,
            encoderMaxWidth: effectiveEncoderMaxWidth,
            encoderMaxHeight: effectiveEncoderMaxHeight,
            disableResolutionCap: disableResolutionCap
        )
        let resolved = plan.resolvedStreamScale

        if resolved < plan.requestedStreamScale, let logLabel {
            MirageLogger.stream(
                "\(logLabel): requested \(plan.requestedStreamScale), capped \(resolved) for \(Int(baseSize.width))x\(Int(baseSize.height))"
            )
        }

        return resolved
    }
}

#endif
