//
//  CaptureStreamOutput+Geometry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Capture frame geometry and stall threshold helpers.
//

import CoreGraphics
import Foundation

#if os(macOS)
extension CaptureStreamOutput {
    /// Window-capture stalls tolerate menu tracking and accessibility pauses.
    static let windowStallThreshold: CFAbsoluteTime = 8.0

    /// Display-capture stalls should recover quickly when frames stop arriving.
    static let displayStallThreshold: CFAbsoluteTime = 0.6

    func fullBufferContentRect(
        bufferWidth: Int,
        bufferHeight: Int
    ) -> CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(bufferWidth), height: CGFloat(bufferHeight))
    }

    func normalizedContentRect(
        _ rect: CGRect,
        bufferWidth: Int,
        bufferHeight: Int
    ) -> CGRect? {
        let fullRect = fullBufferContentRect(bufferWidth: bufferWidth, bufferHeight: bufferHeight)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let sanitized = rect.intersection(fullRect)
        guard sanitized.width > 0, sanitized.height > 0 else { return nil }
        return sanitized
    }

    static func resolvedStallLimit(
        windowID: CGWindowID,
        configuredStallLimit: CFAbsoluteTime,
        displayStallThreshold: CFAbsoluteTime = 0.6,
        windowStallThreshold: CFAbsoluteTime = 8.0
    )
    -> CFAbsoluteTime {
        if windowID == 0 {
            let minDisplayThreshold = max(0.6, min(displayStallThreshold, 1.0))
            let maxDisplayThreshold: CFAbsoluteTime = 4.0
            return min(max(configuredStallLimit, minDisplayThreshold), maxDisplayThreshold)
        }
        return max(configuredStallLimit, windowStallThreshold)
    }
}
#endif
