//
//  WindowCaptureEngine+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Capture engine helper calculations.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import MirageKit

#if os(macOS)
import AppKit
import ScreenCaptureKit

extension WindowCaptureEngine {
    var captureQueueDepth: Int {
        if let override = configuration.captureQueueDepth, override > 0 {
            return min(max(1, override), 8)
        }

        let width = max(1, currentWidth)
        let height = max(1, currentHeight)
        let pixelCount = max(1, width * height)
        let basePixels = 1920 * 1080
        let extraPixels = max(0, pixelCount - basePixels)
        let extraDepth = extraPixels / 2_500_000

        var depth = 3 + extraDepth
        if currentFrameRate >= 120 { depth += 1 }

        switch latencyMode {
        case .lowestLatency:
            depth -= 1
        case .auto:
            depth += 1
        case .smoothest:
            depth += 1
        }

        let minDepth: Int = switch latencyMode {
        case .lowestLatency: 2
        case .auto: 4
        case .smoothest: 4
        }

        depth = max(depth, minDepth)
        return min(max(1, depth), 8)
    }

    var bufferPoolMinimumCount: Int {
        let extra: Int = switch latencyMode {
        case .lowestLatency:
            currentFrameRate >= 120 ? 3 : 2
        case .auto:
            currentFrameRate >= 120 ? 6 : 5
        case .smoothest:
            currentFrameRate >= 120 ? 6 : 5
        }
        return max(6, captureQueueDepth + extra)
    }

    func updateDisplayRefreshRate(for displayID: CGDirectDisplayID) {
        guard let displayMode = CGDisplayCopyDisplayMode(displayID) else {
            currentDisplayRefreshRate = nil
            return
        }
        let refreshRate = displayMode.refreshRate
        if refreshRate > 0 { currentDisplayRefreshRate = Int(refreshRate.rounded()) } else {
            currentDisplayRefreshRate = nil
        }
    }

    func minimumFrameIntervalRate() -> Int {
        currentFrameRate
    }

    func effectiveCaptureRate() -> Int {
        if usesDisplayRefreshCadence, let refreshRate = currentDisplayRefreshRate, refreshRate > 0 {
            return refreshRate
        }
        return currentFrameRate
    }

    func resolvedMinimumFrameInterval() -> CMTime {
        if usesDisplayRefreshCadence { return .zero }
        return CMTime(value: 1, timescale: CMTimeScale(minimumFrameIntervalRate()))
    }

    func frameGapThreshold(for frameRate: Int) -> CFAbsoluteTime {
        if frameRate >= 120 { return 0.18 }
        if frameRate >= 60 { return 0.30 }
        if frameRate >= 30 { return 0.50 }
        return 1.5
    }

    func stallThreshold(for frameRate: Int) -> CFAbsoluteTime {
        if frameRate >= 120 { return 2.5 }
        if frameRate >= 60 { return 2.0 }
        if frameRate >= 30 { return 2.5 }
        return 4.0
    }

    var pixelFormatType: OSType {
        switch configuration.pixelFormat {
        case .p010:
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .bgr10a2:
            kCVPixelFormatType_ARGB2101010LEPacked
        case .bgra8:
            kCVPixelFormatType_32BGRA
        case .nv12:
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }

    static func alignedEvenPixel(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let even = rounded - (rounded % 2)
        return max(even, 2)
    }
}

#endif
