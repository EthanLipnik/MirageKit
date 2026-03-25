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
        let clampedRequested = StreamContext.clampStreamScale(requestedScale)
        guard baseSize.width > 0, baseSize.height > 0 else { return clampedRequested }
        if disableResolutionCap { return clampedRequested }

        let maxScale = min(
            1.0,
            Self.maxEncodedWidth / baseSize.width,
            Self.maxEncodedHeight / baseSize.height
        )
        let resolved = min(clampedRequested, maxScale)

        if resolved < clampedRequested, let logLabel {
            MirageLogger.stream(
                "\(logLabel): requested \(clampedRequested), capped \(resolved) for \(Int(baseSize.width))x\(Int(baseSize.height))"
            )
        }

        return resolved
    }

    /// Align a pixel dimension to a 16-byte boundary.  Hardware video encoders
    /// (HEVC on Apple Silicon) require both width and height to be multiples of
    /// 16 for NV12/P010 pixel formats; unaligned dimensions cause silent encode
    /// failures during preheat.
    static func alignedEvenPixel(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let aligned = rounded & ~15 // round down to nearest multiple of 16
        return max(aligned, 16)
    }
}

#endif
