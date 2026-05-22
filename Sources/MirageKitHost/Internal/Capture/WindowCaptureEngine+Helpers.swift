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
    nonisolated static let highResolutionPixelThreshold = 3840 * 2160

    nonisolated static func isHighResolutionCapture(width: Int, height: Int) -> Bool {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        return safeWidth * safeHeight >= highResolutionPixelThreshold
    }

    nonisolated static func resolveSCKQueueDepth(
        width: Int,
        height: Int,
        frameRate: Int,
        latencyMode: MirageStreamLatencyMode,
        hostBufferingPolicy: MirageHostBufferingPolicy = .stability,
        overrideDepth: Int?,
        usesDisplayRefreshCadence: Bool = false
    ) -> Int {
        if let overrideDepth, overrideDepth > 0 {
            return min(max(3, overrideDepth), 8)
        }

        if latencyMode == .lowestLatency, hostBufferingPolicy == .freshestFrame {
            return 3
        }
        if latencyMode == .balanced, hostBufferingPolicy == .freshestFrame {
            if frameRate >= 120 { return 8 }
            if frameRate >= 90 { return 6 }
            return 4
        }

        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        if usesDisplayRefreshCadence, frameRate >= 60 {
            return 8
        }
        if frameRate >= 120 {
            // Native-refresh capture is where SCK is most sensitive to queue starvation.
            // Keep the stream queue at the platform-supported ceiling and use Mirage's
            // own pool/in-flight tuning to reduce downstream pressure instead.
            return 8
        }

        var depth = 6
        if isHighResolutionCapture(width: safeWidth, height: safeHeight) {
            depth += 1
        }
        if safeWidth * safeHeight >= 5120 * 2880 {
            depth += 1
        }

        switch latencyMode {
        case .lowestLatency:
            break
        case .balanced:
            depth += 0
        case .smoothest:
            depth += 1
        }

        return min(max(3, depth), 8)
    }

    nonisolated static func resolveStallPolicy(
        windowID: CGWindowID,
        captureMode: CaptureMode,
        latencyMode: MirageStreamLatencyMode,
        configuredSoftStallLimit: CFAbsoluteTime,
        displayStallThreshold: CFAbsoluteTime = 0.6,
        windowStallThreshold: CFAbsoluteTime = 8.0
    ) -> CaptureStallPolicy {
        if captureMode == .display, windowID == 0 {
            let safeConfiguredSoft = max(0, configuredSoftStallLimit)
            let soft: CFAbsoluteTime
            let hard: CFAbsoluteTime
            let debounce: CFAbsoluteTime

            switch latencyMode {
            case .smoothest:
                soft = min(max(safeConfiguredSoft, 0.60), 1.00)
                hard = min(max(max(soft + 5.00, soft * 6.00), 5.50), 8.00)
                debounce = 0.60
            case .balanced:
                soft = min(max(safeConfiguredSoft, 0.80), 1.40)
                hard = min(max(max(soft + 4.00, soft * 5.00), 5.00), 7.00)
                debounce = 0.45
            case .lowestLatency:
                soft = min(max(safeConfiguredSoft, 1.20), 2.00)
                hard = min(max(max(soft + 3.00, soft * 4.00), 4.50), 6.00)
                debounce = 0.40
            }

            return CaptureStallPolicy(
                softStallThreshold: soft,
                hardRestartThreshold: hard,
                restartDebounce: debounce,
                cancellationGrace: 0.75
            )
        }

        let soft = CaptureStreamOutput.resolvedStallLimit(
            windowID: windowID,
            configuredStallLimit: configuredSoftStallLimit,
            displayStallThreshold: displayStallThreshold,
            windowStallThreshold: windowStallThreshold
        )

        if captureMode == .display {
            // App-stream display capture for a specific window can be quiescent for long periods.
            // Avoid aggressive restart loops that churn virtual displays and spike host CPU.
            // Keep soft-stall signaling for diagnostics/recovery signals, but make hard restart
            // a last-resort path for extended no-frame windows.
            let hard = min(max(soft * 10.0, soft + 60.0), 120.0)
            return CaptureStallPolicy(
                softStallThreshold: soft,
                hardRestartThreshold: hard,
                restartDebounce: 0.60,
                cancellationGrace: 0.75
            )
        }

        return CaptureStallPolicy(
            softStallThreshold: soft,
            hardRestartThreshold: soft,
            restartDebounce: 0.05,
            cancellationGrace: 0.20
        )
    }

    func resolvedStallPolicy(windowID: CGWindowID, frameRate: Int, captureMode: CaptureMode) -> CaptureStallPolicy {
        Self.resolveStallPolicy(
            windowID: windowID,
            captureMode: captureMode,
            latencyMode: latencyMode,
            configuredSoftStallLimit: stallThreshold(for: frameRate)
        )
    }

    var sckQueueDepth: Int {
        Self.resolveSCKQueueDepth(
            width: currentWidth,
            height: currentHeight,
            frameRate: currentFrameRate,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            overrideDepth: configuration.captureQueueDepth,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence
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

    nonisolated static func resolvedEffectiveCaptureRate(
        requestedFrameRate: Int,
        displayRefreshRate: Int?,
        usesDisplayRefreshCadence: Bool,
        minimumFrameIntervalPolicy: MinimumFrameIntervalPolicy = .automatic,
        prefersExplicitHighRefreshInterval: Bool = false
    ) -> Int {
        let requestedFrameRate = max(1, requestedFrameRate)
        switch minimumFrameIntervalPolicy {
        case .explicitTarget:
            return requestedFrameRate
        case .nativeRefresh:
            guard let displayRefreshRate = resolvedDisplayRefreshRateForCadence(
                requestedFrameRate: requestedFrameRate,
                displayRefreshRate: displayRefreshRate,
                usesDisplayRefreshCadence: true
            ) else {
                return requestedFrameRate
            }
            return max(1, min(requestedFrameRate, displayRefreshRate))
        case .automatic:
            if prefersExplicitHighRefreshInterval {
                return requestedFrameRate
            }
        }
        guard usesDisplayRefreshCadence else {
            return requestedFrameRate
        }
        guard let displayRefreshRate = resolvedDisplayRefreshRateForCadence(
            requestedFrameRate: requestedFrameRate,
            displayRefreshRate: displayRefreshRate,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence
        ) else { return requestedFrameRate }
        return max(1, min(requestedFrameRate, displayRefreshRate))
    }

    nonisolated static func usesNativeRefreshMinimumFrameInterval(
        requestedFrameRate: Int,
        displayRefreshRate: Int?,
        usesDisplayRefreshCadence: Bool,
        minimumFrameIntervalPolicy: MinimumFrameIntervalPolicy = .automatic,
        prefersExplicitHighRefreshInterval: Bool = false
    ) -> Bool {
        switch minimumFrameIntervalPolicy {
        case .explicitTarget:
            return false
        case .nativeRefresh:
            return true
        case .automatic:
            if prefersExplicitHighRefreshInterval {
                return false
            }
        }
        guard usesDisplayRefreshCadence,
              let displayRefreshRate = resolvedDisplayRefreshRateForCadence(
                  requestedFrameRate: requestedFrameRate,
                  displayRefreshRate: displayRefreshRate,
                  usesDisplayRefreshCadence: usesDisplayRefreshCadence
              ) else {
            return false
        }
        return max(1, requestedFrameRate) >= displayRefreshRate
    }

    nonisolated static func resolvedDisplayRefreshRateForCadence(
        requestedFrameRate: Int,
        displayRefreshRate: Int?,
        usesDisplayRefreshCadence: Bool
    ) -> Int? {
        guard usesDisplayRefreshCadence else { return displayRefreshRate }
        if let displayRefreshRate, displayRefreshRate > 0 {
            return displayRefreshRate
        }
        let requestedFrameRate = max(1, requestedFrameRate)
        guard requestedFrameRate >= 60 else { return nil }
        return min(requestedFrameRate, 120)
    }

    nonisolated static func resolvedMinimumFrameInterval(
        requestedFrameRate: Int,
        displayRefreshRate: Int?,
        usesDisplayRefreshCadence: Bool,
        minimumFrameIntervalPolicy: MinimumFrameIntervalPolicy = .automatic,
        prefersExplicitHighRefreshInterval: Bool = false
    ) -> CMTime {
        if usesNativeRefreshMinimumFrameInterval(
            requestedFrameRate: requestedFrameRate,
            displayRefreshRate: displayRefreshRate,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence,
            minimumFrameIntervalPolicy: minimumFrameIntervalPolicy,
            prefersExplicitHighRefreshInterval: prefersExplicitHighRefreshInterval
        ) {
            return .zero
        }
        let effectiveRate = resolvedEffectiveCaptureRate(
            requestedFrameRate: requestedFrameRate,
            displayRefreshRate: displayRefreshRate,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence,
            minimumFrameIntervalPolicy: minimumFrameIntervalPolicy,
            prefersExplicitHighRefreshInterval: prefersExplicitHighRefreshInterval
        )
        return CMTime(value: 1, timescale: CMTimeScale(effectiveRate))
    }

    var minimumFrameIntervalRate: Int {
        Self.resolvedEffectiveCaptureRate(
            requestedFrameRate: currentFrameRate,
            displayRefreshRate: currentDisplayRefreshRate,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence,
            minimumFrameIntervalPolicy: minimumFrameIntervalPolicy,
            prefersExplicitHighRefreshInterval: prefersExplicitHighRefreshInterval
        )
    }

    var usesNativeRefreshMinimumFrameInterval: Bool {
        Self.usesNativeRefreshMinimumFrameInterval(
            requestedFrameRate: currentFrameRate,
            displayRefreshRate: currentDisplayRefreshRate,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence,
            minimumFrameIntervalPolicy: minimumFrameIntervalPolicy,
            prefersExplicitHighRefreshInterval: prefersExplicitHighRefreshInterval
        )
    }

    var resolvedMinimumFrameInterval: CMTime {
        Self.resolvedMinimumFrameInterval(
            requestedFrameRate: currentFrameRate,
            displayRefreshRate: currentDisplayRefreshRate,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence,
            minimumFrameIntervalPolicy: minimumFrameIntervalPolicy,
            prefersExplicitHighRefreshInterval: prefersExplicitHighRefreshInterval
        )
    }

    var prefersExplicitHighRefreshInterval: Bool {
        guard captureMode == .display,
              currentFrameRate >= 120 else {
            return false
        }
        let windowID = captureSessionConfig?.windowID ?? 0
        return windowID == 0
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
        case .xf44, .ayuv16:
            kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
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

    var captureColorSpaceName: CFString {
        switch configuration.colorSpace {
        case .displayP3:
            CGColorSpace.displayP3
        case .sRGB:
            CGColorSpace.sRGB
        }
    }
}

#endif
