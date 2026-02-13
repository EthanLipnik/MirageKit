//
//  WindowCaptureEngine.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreMedia
import CoreVideo
import Foundation
import os
import MirageKit

#if os(macOS)
import AppKit
import CoreGraphics
import ScreenCaptureKit

actor WindowCaptureEngine {
    enum CaptureKeyframeRequestReason: Sendable, Equatable {
        case fallbackResume
        case captureRestart(restartStreak: Int, shouldEscalateRecovery: Bool)

        var requiresEpochReset: Bool {
            switch self {
            case .fallbackResume:
                false
            case let .captureRestart(_, shouldEscalateRecovery):
                shouldEscalateRecovery
            }
        }
    }

    var stream: SCStream?
    var streamOutput: CaptureStreamOutput?
    var configuration: MirageEncoderConfiguration
    let latencyMode: MirageStreamLatencyMode
    var currentFrameRate: Int
    let usesDisplayRefreshCadence: Bool
    var currentDisplayRefreshRate: Int?
    var admissionDropper: (@Sendable () -> Bool)?
    var pendingKeyframeRequest: CaptureKeyframeRequestReason?
    var isCapturing = false
    var isRestarting = false
    var capturedFrameHandler: (@Sendable (CapturedFrame) -> Void)?
    var capturedAudioHandler: (@Sendable (CapturedAudioBuffer) -> Void)?
    var dimensionChangeHandler: (@Sendable (Int, Int) -> Void)?
    var captureMode: CaptureMode?
    var captureSessionConfig: CaptureSessionConfiguration?

    // Track current dimensions to detect changes
    var currentWidth: Int = 0
    var currentHeight: Int = 0
    var currentScaleFactor: CGFloat = 1.0
    var outputScale: CGFloat = 1.0
    var useBestCaptureResolution: Bool = true
    var useExplicitCaptureDimensions: Bool = true
    var contentFilter: SCContentFilter?
    var excludedWindows: [SCWindow] = []
    var lastRestartAttemptTime: CFAbsoluteTime = 0
    var restartStreak: Int = 0
    let restartCooldownBase: CFAbsoluteTime = 3.0
    let restartBackoffMultiplier: Double = 2.0
    let restartCooldownCap: CFAbsoluteTime = 18.0
    let restartStreakResetWindow: CFAbsoluteTime = 20.0
    let hardRecoveryEscalationThreshold: Int = 3
    var restartGeneration: UInt64 = 0

    nonisolated static func restartCooldown(
        for streak: Int,
        base: CFAbsoluteTime = 3.0,
        multiplier: Double = 2.0,
        cap: CFAbsoluteTime = 18.0
    )
    -> CFAbsoluteTime {
        let clampedStreak = max(1, streak)
        let exponent = max(0, clampedStreak - 1)
        return min(base * pow(multiplier, Double(exponent)), cap)
    }

    nonisolated static func shouldEscalateRecovery(
        restartStreak: Int,
        threshold: Int = 3
    )
    -> Bool {
        restartStreak >= max(1, threshold)
    }

    nonisolated static func shouldResetRestartStreak(
        now: CFAbsoluteTime,
        lastRestartAttemptTime: CFAbsoluteTime,
        resetWindow: CFAbsoluteTime = 20.0
    )
    -> Bool {
        guard lastRestartAttemptTime > 0 else { return false }
        return now - lastRestartAttemptTime > resetWindow
    }

    init(
        configuration: MirageEncoderConfiguration,
        latencyMode: MirageStreamLatencyMode = .auto,
        captureFrameRate: Int? = nil,
        usesDisplayRefreshCadence: Bool = false
    ) {
        self.configuration = configuration
        self.latencyMode = latencyMode
        currentFrameRate = max(1, captureFrameRate ?? configuration.targetFrameRate)
        self.usesDisplayRefreshCadence = usesDisplayRefreshCadence
    }

    enum CaptureMode {
        case window
        case display
    }

    struct CaptureSessionConfiguration {
        let windowID: WindowID?
        let applicationPID: pid_t?
        let displayID: CGDirectDisplayID
        let window: SCWindow?
        let application: SCRunningApplication?
        let display: SCDisplay
        let knownScaleFactor: CGFloat?
        let outputScale: CGFloat
        let resolution: CGSize?
        let showsCursor: Bool
        let excludedWindows: [SCWindow]
    }

    func setAdmissionDropper(_ dropper: (@Sendable () -> Bool)?) {
        admissionDropper = dropper
    }
}

#endif
