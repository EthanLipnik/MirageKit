//
//  WindowCaptureEngine+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Capture engine helper calculations.
//

import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import os

#if os(macOS)
import ScreenCaptureKit
import AppKit

extension WindowCaptureEngine {
    var captureQueueDepth: Int {
        if let override = configuration.captureQueueDepth, override > 0 {
            return min(max(1, override), 16)
        }
        switch latencyMode {
        case .lowestLatency:
            if currentFrameRate >= 120 {
                return 6
            }
            if currentFrameRate >= 60 {
                return 4
            }
            return 3
        case .balanced:
            if currentFrameRate >= 120 {
                return 8
            }
            if currentFrameRate >= 60 {
                return 6
            }
            return 4
        case .smoothest:
            if currentFrameRate >= 120 {
                return 10
            }
            if currentFrameRate >= 60 {
                return 8
            }
            return 6
        }
    }

    var bufferPoolMinimumCount: Int {
        let extra: Int
        switch latencyMode {
        case .lowestLatency:
            extra = currentFrameRate >= 120 ? 3 : 2
        case .balanced:
            extra = currentFrameRate >= 120 ? 4 : 3
        case .smoothest:
            extra = currentFrameRate >= 120 ? 6 : 5
        }
        return max(6, captureQueueDepth + extra)
    }

    func updateDisplayRefreshRate(for displayID: CGDirectDisplayID) {
        guard let displayMode = CGDisplayCopyDisplayMode(displayID) else {
            currentDisplayRefreshRate = nil
            return
        }
        let refreshRate = displayMode.refreshRate
        if refreshRate > 0 {
            currentDisplayRefreshRate = Int(refreshRate.rounded())
        } else {
            currentDisplayRefreshRate = nil
        }
    }

    func minimumFrameIntervalRate() -> Int {
        if let refreshRate = currentDisplayRefreshRate, refreshRate > 0 {
            // Never request a faster cadence than our target capture rate.
            // Using the display refresh rate here can make SCK deliver at 120Hz,
            // forcing the pacing controller to drop roughly half the frames.
            return min(currentFrameRate, refreshRate)
        }
        return currentFrameRate
    }

    func frameGapThreshold(for frameRate: Int) -> CFAbsoluteTime {
        if frameRate >= 120 {
            return 0.18
        }
        if frameRate >= 60 {
            return 0.30
        }
        if frameRate >= 30 {
            return 0.50
        }
        return 1.5
    }

    func stallThreshold(for frameRate: Int) -> CFAbsoluteTime {
        if frameRate >= 120 {
            return 2.5
        }
        if frameRate >= 60 {
            return 2.0
        }
        if frameRate >= 30 {
            return 2.5
        }
        return 4.0
    }

    var pixelFormatType: OSType {
        switch configuration.pixelFormat {
        case .p010:
            return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .bgr10a2:
            return kCVPixelFormatType_ARGB2101010LEPacked
        case .bgra8:
            return kCVPixelFormatType_32BGRA
        case .nv12:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }

    static func alignedEvenPixel(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        let even = rounded - (rounded % 2)
        return max(even, 2)
    }
}

#endif
