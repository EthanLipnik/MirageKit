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
    nonisolated static let highResolutionPixelThreshold = 3_840 * 2_160

    nonisolated static func isHighResolutionCapture(width: Int, height: Int) -> Bool {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        return safeWidth * safeHeight >= highResolutionPixelThreshold
    }

    nonisolated static func resolveCaptureQueueDepth(
        width: Int,
        height: Int,
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode,
        profile: CapturePressureProfile,
        overrideDepth: Int?
    ) -> Int {
        if let overrideDepth, overrideDepth > 0 {
            return min(max(1, overrideDepth), 8)
        }

        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        let pixelCount = max(1, safeWidth * safeHeight)
        let basePixels = 1920 * 1080
        let extraPixels = max(0, pixelCount - basePixels)
        let extraDepth = extraPixels / 2_500_000

        var depth = 3 + extraDepth
        if frameRate >= 120 { depth += 1 }

        switch latencyMode {
        case .lowestLatency:
            depth -= 1
        case .auto:
            depth += 1
        case .smoothest:
            depth += 1
        }

        let tunedHighResLowestLatency = profile == .tuned &&
            latencyMode == .lowestLatency &&
            isHighResolutionCapture(width: safeWidth, height: safeHeight)
        if tunedHighResLowestLatency {
            depth -= frameRate >= 120 ? 2 : 1
        }

        let minDepth: Int = {
            switch latencyMode {
            case .lowestLatency:
                if profile == .tuned,
                   isHighResolutionCapture(width: safeWidth, height: safeHeight) {
                    return 1
                }
                return 2
            case .auto:
                return 4
            case .smoothest:
                return 4
            }
        }()

        depth = max(depth, minDepth)

        if tunedHighResLowestLatency {
            let tunedCap = frameRate >= 120 ? 7 : 6
            return min(max(1, depth), tunedCap)
        }

        return min(max(1, depth), 8)
    }

    nonisolated static func resolveBufferPoolMinimumCount(
        queueDepth: Int,
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode,
        profile: CapturePressureProfile,
        highResolutionCapture: Bool
    ) -> Int {
        var extra: Int = switch latencyMode {
        case .lowestLatency:
            frameRate >= 120 ? 3 : 2
        case .auto:
            frameRate >= 120 ? 6 : 5
        case .smoothest:
            frameRate >= 120 ? 6 : 5
        }

        var minimum = 6
        if profile == .tuned,
           latencyMode == .lowestLatency,
           highResolutionCapture {
            if frameRate >= 120 {
                extra = max(1, extra - 2)
                minimum = 5
            } else {
                extra = max(1, extra - 1)
                minimum = 4
            }
        }

        return max(minimum, queueDepth + extra)
    }

    nonisolated static func resolveStallPolicy(
        windowID: CGWindowID,
        frameRate: Int,
        configuredSoftStallLimit: CFAbsoluteTime,
        displayStallThreshold: CFAbsoluteTime = 1.5,
        windowStallThreshold: CFAbsoluteTime = 8.0
    ) -> CaptureStallPolicy {
        let soft = CaptureStreamOutput.resolvedStallLimit(
            windowID: windowID,
            configuredStallLimit: configuredSoftStallLimit,
            displayStallThreshold: displayStallThreshold,
            windowStallThreshold: windowStallThreshold
        )

        if windowID == 0 {
            let hard = min(max(soft * 2.0, soft + 1.5), 8.0)
            let debounce: CFAbsoluteTime = frameRate >= 120 ? 0.45 : 0.35
            return CaptureStallPolicy(
                softStallThreshold: soft,
                hardRestartThreshold: hard,
                restartDebounce: debounce,
                cancellationGrace: 0.30
            )
        }

        return CaptureStallPolicy(
            softStallThreshold: soft,
            hardRestartThreshold: soft,
            restartDebounce: 0.05,
            cancellationGrace: 0.20
        )
    }

    func resolvedStallPolicy(windowID: CGWindowID, frameRate: Int) -> CaptureStallPolicy {
        Self.resolveStallPolicy(
            windowID: windowID,
            frameRate: frameRate,
            configuredSoftStallLimit: stallThreshold(for: frameRate)
        )
    }

    var captureQueueDepth: Int {
        Self.resolveCaptureQueueDepth(
            width: currentWidth,
            height: currentHeight,
            frameRate: currentFrameRate,
            latencyMode: latencyMode,
            profile: capturePressureProfile,
            overrideDepth: configuration.captureQueueDepth
        )
    }

    var bufferPoolMinimumCount: Int {
        let highResolutionCapture = Self.isHighResolutionCapture(width: currentWidth, height: currentHeight)
        return Self.resolveBufferPoolMinimumCount(
            queueDepth: captureQueueDepth,
            frameRate: currentFrameRate,
            latencyMode: latencyMode,
            profile: capturePressureProfile,
            highResolutionCapture: highResolutionCapture
        )
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
