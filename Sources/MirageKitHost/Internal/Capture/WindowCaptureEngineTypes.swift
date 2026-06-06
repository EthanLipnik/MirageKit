//
//  WindowCaptureEngineTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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
import Foundation

#if os(macOS)
import ScreenCaptureKit

extension WindowCaptureEngine {
    /// Capture tuning profile selected for ScreenCaptureKit pressure behavior.
    enum CapturePressureProfile: String, Equatable {
        case baseline
        case tuned

        nonisolated static func parse(_ rawValue: String?) -> Self? {
            guard let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return nil
            }
            switch normalized {
            case "baseline":
                return .baseline
            case "tuned":
                return .tuned
            default:
                return nil
            }
        }
    }

    /// Timing thresholds used when escalating stalled capture output.
    struct CaptureStallPolicy: Equatable {
        let softStallThreshold: CFAbsoluteTime
        let hardRestartThreshold: CFAbsoluteTime
        let restartDebounce: CFAbsoluteTime
        let cancellationGrace: CFAbsoluteTime
    }

    /// ScreenCaptureKit frame-interval strategy in force for the active stream.
    enum MinimumFrameIntervalPolicy: String, Sendable, Equatable {
        /// Use the normal resolver, except high-refresh desktop display capture starts with an explicit target interval.
        case automatic
        /// Force `minimumFrameInterval` to `1 / requestedFrameRate`.
        case explicitTarget
        /// Force native display-cadence delivery with `.zero`.
        case nativeRefresh
    }

    /// Snapshot of effective capture settings exposed to benchmark reporting.
    struct CapturePolicySnapshot: Equatable {
        let effectiveCaptureRate: Int
        let minimumFrameIntervalRate: Int
        let usesNativeRefreshMinimumFrameInterval: Bool
        let minimumFrameIntervalPolicy: MinimumFrameIntervalPolicy
        let sckQueueDepth: Int
        let usesDisplayRefreshCadence: Bool
        let displayRefreshRate: Int?

        var benchmarkPolicy: MirageDiagnostics.MirageHostCaptureBenchmarkCapturePolicy {
            MirageDiagnostics.MirageHostCaptureBenchmarkCapturePolicy(
                effectiveCaptureRate: effectiveCaptureRate,
                minimumFrameIntervalRate: minimumFrameIntervalRate,
                usesNativeRefreshMinimumFrameInterval: usesNativeRefreshMinimumFrameInterval,
                sckQueueDepth: sckQueueDepth,
                usesDisplayRefreshCadence: usesDisplayRefreshCadence
            )
        }
    }

    /// Reason a capture engine requested a replacement keyframe.
    enum CaptureKeyframeRequestReason: Equatable {
        case captureRestart(restartStreak: Int, shouldEscalateRecovery: Bool)
    }

    /// ScreenCaptureKit source family currently owned by the engine.
    enum CaptureMode {
        case window
        case display
    }

    /// Immutable source metadata needed to rebuild ScreenCaptureKit filters and configurations.
    struct CaptureSessionConfiguration {
        let windowID: WindowID?
        let applicationPID: pid_t?
        let displayID: CGDirectDisplayID
        let window: SCWindow?
        let application: SCRunningApplication?
        let display: SCDisplay
        let outputScale: CGFloat
        let resolution: CGSize?
        let sourceRect: CGRect?
        let destinationRect: CGRect?
        let showsCursor: Bool
        let audioChannelCount: Int?
        let includedWindows: [SCWindow]
        let excludedWindows: [SCWindow]

        init(
            windowID: WindowID?,
            applicationPID: pid_t?,
            displayID: CGDirectDisplayID,
            window: SCWindow?,
            application: SCRunningApplication?,
            display: SCDisplay,
            outputScale: CGFloat,
            resolution: CGSize?,
            sourceRect: CGRect?,
            destinationRect: CGRect? = nil,
            showsCursor: Bool,
            audioChannelCount: Int?,
            includedWindows: [SCWindow] = [],
            excludedWindows: [SCWindow] = []
        ) {
            self.windowID = windowID
            self.applicationPID = applicationPID
            self.displayID = displayID
            self.window = window
            self.application = application
            self.display = display
            self.outputScale = outputScale
            self.resolution = resolution
            self.sourceRect = sourceRect
            self.destinationRect = destinationRect
            self.showsCursor = showsCursor
            self.audioChannelCount = audioChannelCount
            self.includedWindows = includedWindows
            self.excludedWindows = excludedWindows
        }
    }
}
#endif
