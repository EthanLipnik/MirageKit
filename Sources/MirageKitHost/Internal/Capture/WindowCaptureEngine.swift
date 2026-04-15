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
    enum CapturePressureProfile: String, Sendable, Equatable {
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

    struct CaptureStallPolicy: Sendable, Equatable {
        let softStallThreshold: CFAbsoluteTime
        let hardRestartThreshold: CFAbsoluteTime
        let restartDebounce: CFAbsoluteTime
        let cancellationGrace: CFAbsoluteTime
    }

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
    let capturePressureProfile: CapturePressureProfile
    let latencyMode: MirageStreamLatencyMode
    var currentFrameRate: Int
    let usesDisplayRefreshCadence: Bool
    var currentDisplayRefreshRate: Int?
    var admissionDropper: (@Sendable () -> Bool)?
    var pendingKeyframeRequest: CaptureKeyframeRequestReason?
    var captureStallStageHandler: (@Sendable (CaptureStreamOutput.StallStage) -> Void)?
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
    /// Display capture with an explicit resolution override (HiDPI virtual displays)
    /// skips `.best` and sets width/height directly.
    var displayUsesExplicitResolution: Bool = false
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
    var activeStallPolicy = CaptureStallPolicy(
        softStallThreshold: 2.0,
        hardRestartThreshold: 4.0,
        restartDebounce: 0.4,
        cancellationGrace: 0.3
    )
    var scheduledRestartTask: Task<Void, Never>?
    var scheduledRestartToken: UInt64 = 0

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
        capturePressureProfile: CapturePressureProfile = .baseline,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        captureFrameRate: Int? = nil,
        usesDisplayRefreshCadence: Bool = false
    ) {
        self.configuration = configuration
        self.capturePressureProfile = capturePressureProfile
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

    nonisolated static func resolvedDisplayFilter(
        display: SCDisplay,
        includedWindows: [SCWindow],
        excludedWindows: [SCWindow]
    ) -> SCContentFilter {
        if !includedWindows.isEmpty {
            return SCContentFilter(display: display, including: includedWindows)
        }
        return SCContentFilter(display: display, excludingWindows: excludedWindows)
    }

    nonisolated static let captureBackgroundColor: CGColor = {
        CGColor(gray: 0, alpha: 1)
    }()

    nonisolated static func applyCaptureGeometry(
        to streamConfig: SCStreamConfiguration,
        sourceRect: CGRect?,
        destinationRect: CGRect?
    ) {
        if let sourceRect, !sourceRect.isEmpty {
            streamConfig.sourceRect = sourceRect
        }
        if let destinationRect, !destinationRect.isEmpty {
            streamConfig.destinationRect = destinationRect
            streamConfig.backgroundColor = captureBackgroundColor
        }
    }

    func setAdmissionDropper(_ dropper: (@Sendable () -> Bool)?) {
        admissionDropper = dropper
    }

    func setCaptureStallStageHandler(_ handler: (@Sendable (CaptureStreamOutput.StallStage) -> Void)?) {
        captureStallStageHandler = handler
    }

    func captureTelemetrySnapshot() -> CaptureStreamOutput.TelemetrySnapshot? {
        streamOutput?.telemetrySnapshot()
    }

    func displayStartupReadiness() -> DisplayCaptureStartupReadiness {
        guard captureMode == .display else { return captureStartupReadiness() }
        return streamOutput?.displayStartupReadiness() ?? .noScreenSamples
    }

    func hasObservedDisplayStartupSample() -> Bool {
        guard captureMode == .display else { return hasObservedCaptureStartupSample() }
        return streamOutput?.hasObservedDisplayStartupSample() ?? false
    }

    func captureStartupReadiness() -> DisplayCaptureStartupReadiness {
        streamOutput?.captureStartupReadiness() ?? .noScreenSamples
    }

    func hasObservedCaptureStartupSample() -> Bool {
        streamOutput?.hasObservedStartupSample() ?? false
    }

    func waitForCaptureStartupReadiness(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50)
    ) async -> DisplayCaptureStartupReadiness {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled {
            let readiness = captureStartupReadiness()
            switch readiness {
            case .usableFrameSeen, .idleFrameSeen:
                return readiness
            case .blankOrSuspendedOnly, .noScreenSamples:
                break
            }
            guard ContinuousClock.now < deadline else { return readiness }
            try? await Task.sleep(for: pollInterval)
        }
        return captureStartupReadiness()
    }

    func waitForDisplayStartupReadiness(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50)
    ) async -> DisplayCaptureStartupReadiness {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled {
            let readiness = displayStartupReadiness()
            switch readiness {
            case .usableFrameSeen, .idleFrameSeen:
                return readiness
            case .blankOrSuspendedOnly, .noScreenSamples:
                break
            }
            guard ContinuousClock.now < deadline else { return readiness }
            try? await Task.sleep(for: pollInterval)
        }
        return displayStartupReadiness()
    }

    func captureDisplayStartupSeedFrame() async -> CapturedFrame? {
        guard captureMode == .display,
              let config = captureSessionConfig else {
            return nil
        }

        let width = max(1, currentWidth)
        let height = max(1, currentHeight)
        let filter = Self.resolvedDisplayFilter(
            display: config.display,
            includedWindows: config.includedWindows,
            excludedWindows: config.excludedWindows
        )
        let screenshotConfiguration = SCStreamConfiguration()
        screenshotConfiguration.width = width
        screenshotConfiguration.height = height
        screenshotConfiguration.showsCursor = config.showsCursor
        screenshotConfiguration.colorSpaceName = captureColorSpaceName
        Self.applyCaptureGeometry(
            to: screenshotConfiguration,
            sourceRect: config.sourceRect,
            destinationRect: config.destinationRect
        )

        let image: CGImage? = try? await withCheckedThrowingContinuation { (
            continuation: CheckedContinuation<CGImage, Error>
        ) in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: screenshotConfiguration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(
                        throwing: MirageError.protocolError(
                            "Display startup screenshot capture returned no image"
                        )
                    )
                    return
                }
                continuation.resume(returning: image)
            }
        }
        guard let image else {
            return nil
        }

        let frame = DisplayStartupFrameSeeder.makeCapturedFrame(
            from: image,
            targetWidth: width,
            targetHeight: height,
            pixelFormatType: pixelFormatType,
            colorSpace: configuration.colorSpace,
            frameRate: currentFrameRate
        )
        if frame != nil {
            MirageLogger.capture(
                "Display startup screenshot seed captured for display \(config.displayID) at \(width)x\(height)"
            )
        }
        return frame
    }

    nonisolated func enqueueKeyframeRequest(_ reason: CaptureStreamOutput.KeyframeRequestReason) {
        Task(priority: .userInitiated) {
            await self.markKeyframeRequested(reason: reason)
        }
    }

    nonisolated func enqueueCaptureStallSignal(_ signal: CaptureStreamOutput.StallSignal) {
        Task(priority: .userInitiated) {
            await self.handleCaptureStallSignal(signal)
        }
    }

    func handleCaptureStallSignal(_ signal: CaptureStreamOutput.StallSignal) {
        captureStallStageHandler?(signal.stage)
        switch signal.stage {
        case .soft:
            MirageLogger
                .capture(
                    "event=stall_detected stage=soft gapMs=\(signal.gapMs) " +
                        "softMs=\(signal.softThresholdMs) hardMs=\(signal.hardThresholdMs)"
                )
        case .hard:
            MirageLogger
                .capture(
                    "event=stall_detected stage=hard gapMs=\(signal.gapMs) " +
                        "softMs=\(signal.softThresholdMs) hardMs=\(signal.hardThresholdMs)"
                )
        case .resumed:
            MirageLogger
                .capture(
                    "event=stall_resumed gapMs=\(signal.gapMs) " +
                        "softMs=\(signal.softThresholdMs) hardMs=\(signal.hardThresholdMs)"
                )
            cancelScheduledCaptureRestart(reason: "frames_resumed_signal")
            return
        }

        guard signal.restartEligible else { return }
        let debounce = activeStallPolicy.restartDebounce
        scheduleCaptureRestart(reason: signal.message, debounce: debounce)
    }

    func scheduleCaptureRestart(reason: String, debounce: CFAbsoluteTime) {
        guard isCapturing, captureMode != nil else { return }
        guard scheduledRestartTask == nil else {
            MirageLogger.capture("event=restart_scheduled state=pending reason=\(reason)")
            return
        }

        scheduledRestartToken &+= 1
        let token = scheduledRestartToken
        let debounceMs = max(0, Int((debounce * 1000).rounded()))
        MirageLogger.capture("event=restart_scheduled debounceMs=\(debounceMs) reason=\(reason)")
        scheduledRestartTask = Task(priority: .userInitiated) {
            if debounceMs > 0 {
                try? await Task.sleep(for: .milliseconds(Int64(debounceMs)))
            }
            await self.executeScheduledCaptureRestart(token: token, reason: reason)
        }
    }

    func cancelScheduledCaptureRestart(reason: String) {
        guard let task = scheduledRestartTask else { return }
        task.cancel()
        scheduledRestartTask = nil
        scheduledRestartToken &+= 1
        MirageLogger.capture("event=restart_canceled reason=\(reason)")
    }

    func executeScheduledCaptureRestart(token: UInt64, reason: String) async {
        guard token == scheduledRestartToken else { return }
        guard !Task.isCancelled else { return }
        scheduledRestartTask = nil

        if captureMode == .display,
           let streamOutput {
            let cancellationGrace = activeStallPolicy.cancellationGrace
            if streamOutput.isRecentlyRecovered(within: cancellationGrace) {
                let graceMs = Int((cancellationGrace * 1000).rounded())
                MirageLogger
                    .capture(
                        "event=restart_canceled reason=frames_resumed graceMs=\(graceMs) source=\(reason)"
                    )
                return
            }
        }

        MirageLogger.capture("event=restart_executed reason=\(reason)")
        await restartCapture(reason: reason)
    }

    func hasScheduledCaptureRestartForTesting() -> Bool {
        scheduledRestartTask != nil
    }

    func setCaptureStateForTesting(isCapturing: Bool, captureMode: CaptureMode?) {
        self.isCapturing = isCapturing
        self.captureMode = captureMode
    }
}

#endif
