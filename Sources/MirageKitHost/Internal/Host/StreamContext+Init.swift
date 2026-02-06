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

    static func alignedEvenPixel(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let even = rounded - (rounded % 2)
        return max(even, 2)
    }
}

#endif
