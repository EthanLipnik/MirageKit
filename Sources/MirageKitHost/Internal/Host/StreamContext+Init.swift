//
//  StreamContext+Init.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Sizing helpers for stream context.
//

import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    func resolvedStreamScale(
        for baseSize: CGSize,
        requestedScale: CGFloat,
        logLabel: String?
    )
    -> CGFloat {
        let plan = MirageStreamGeometry.resolveEncodedPlan(
            basePixelSize: baseSize,
            requestedStreamScale: requestedScale,
            encoderMaxWidth: encoderMaxWidth ?? Int(Self.maxEncodedWidth),
            encoderMaxHeight: encoderMaxHeight ?? Int(Self.maxEncodedHeight),
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

    /// Align a pixel dimension to a 16-byte boundary.  Hardware video encoders
    /// (HEVC on Apple Silicon) require both width and height to be multiples of
    /// 16 for NV12/P010 pixel formats; unaligned dimensions cause silent encode
    /// failures during preheat.
    static func alignedEvenPixel(_ value: CGFloat) -> Int {
        MirageStreamGeometry.alignedEncodedDimension(value)
    }
}

#endif
