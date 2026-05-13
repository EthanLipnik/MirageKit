//
//  WindowCaptureEngine+Lifecycle.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

#if os(macOS)
extension WindowCaptureEngine {
    /// Stops the active capture session and clears restart/session state.
    func stopCapture() async {
        await stopCapture(clearSessionState: true)
    }

    /// Stops the active capture stream, optionally preserving session configuration for restart.
    private func stopCapture(clearSessionState: Bool) async {
        if clearSessionState { restartGeneration &+= 1 }
        cancelScheduledCaptureRestart(reason: clearSessionState ? "capture_stop" : "capture_restart")
        guard isCapturing || stream != nil else {
            if clearSessionState {
                stream = nil
                streamOutput = nil
                isAudioCaptureConfigured = false
                captureSessionConfig = nil
                captureMode = nil
                capturedFrameHandler = nil
                capturedAudioHandler = nil
                isRestarting = false
                pendingKeyframeRequest = nil
                restartStreak = 0
                lastRestartAttemptTime = 0
            }
            return
        }

        isCapturing = false

        do {
            MirageLogger.capture("event=stream_lifecycle phase=stop_attempt mode=\(captureMode == .display ? "display" : "window")")
            try await stream?.stopCapture()
            MirageLogger.capture("event=stream_lifecycle phase=stop_success mode=\(captureMode == .display ? "display" : "window")")
        } catch {
            if Self.isExpectedStopCaptureError(error) {
                MirageLogger.capture("Stop capture returned expected teardown status: \(error.localizedDescription)")
            } else {
                MirageLogger.error(.capture, error: error, message: "Error stopping capture: ")
            }
        }

        stream = nil
        streamOutput = nil
        isAudioCaptureConfigured = false
        if clearSessionState {
            captureSessionConfig = nil
            captureMode = nil
            capturedFrameHandler = nil
            capturedAudioHandler = nil
            isRestarting = false
            pendingKeyframeRequest = nil
            restartStreak = 0
            lastRestartAttemptTime = 0
        }
    }

    private nonisolated static func isExpectedStopCaptureError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
           expectedStopCaptureCodes.contains(nsError.code) {
            return true
        }
        return false
    }

    private nonisolated static let expectedStopCaptureCodes: Set<Int> = [
        -3808, // Stream already stopped / interrupted during teardown.
    ]

    /// Restarts capture from the retained session configuration after a stall or keyframe recovery trigger.
    func restartCapture(reason: String) async {
        cancelScheduledCaptureRestart(reason: "restart_begin")
        guard !isRestarting else { return }
        guard let config = captureSessionConfig, let mode = captureMode else { return }
        guard isCapturing else { return }
        guard let onFrame = capturedFrameHandler else { return }
        let onAudio = capturedAudioHandler
        let now = CFAbsoluteTimeGetCurrent()

        if restartStreak > 0,
           Self.shouldResetRestartStreak(
               now: now,
               lastRestartAttemptTime: lastRestartAttemptTime,
               resetWindow: restartStreakResetWindow
           ) {
            MirageLogger.capture("Capture restart streak reset after stable interval")
            restartStreak = 0
        }

        let requiredCooldown = Self.restartCooldown(
            for: max(1, restartStreak),
            base: restartCooldownBase,
            multiplier: restartBackoffMultiplier,
            cap: restartCooldownCap
        )
        if lastRestartAttemptTime > 0 {
            let elapsed = now - lastRestartAttemptTime
            if elapsed <= requiredCooldown {
                let remainingMs = Int(((requiredCooldown - elapsed) * 1000).rounded())
                MirageLogger
                    .capture(
                        "Capture restart suppressed (\(reason)); cooldown \(remainingMs)ms remaining (streak \(restartStreak))"
                    )
                return
            }
        }

        let restartGeneration = self.restartGeneration

        isRestarting = true
        defer { isRestarting = false }
        restartStreak += 1
        let activeRestartStreak = restartStreak
        lastRestartAttemptTime = now
        let shouldEscalateRecovery = Self.shouldEscalateRecovery(
            restartStreak: activeRestartStreak,
            threshold: hardRecoveryEscalationThreshold
        )
        let nextCooldown = Self.restartCooldown(
            for: activeRestartStreak,
            base: restartCooldownBase,
            multiplier: restartBackoffMultiplier,
            cap: restartCooldownCap
        )
        MirageLogger
            .capture(
                "event=restart_executed reason=\(reason) streak=\(activeRestartStreak) " +
                    "escalate=\(shouldEscalateRecovery) nextCooldownMs=\(Int((nextCooldown * 1000).rounded()))"
            )

        if mode == .display,
           let streamOutput {
            let cancellationGrace = activeStallPolicy.cancellationGrace
            if streamOutput.isRecentlyRecovered(within: cancellationGrace) {
                let graceMs = Int((cancellationGrace * 1000).rounded())
                MirageLogger
                    .capture(
                        "event=restart_canceled reason=frames_resumed_before_stop graceMs=\(graceMs) source=\(reason)"
                    )
                return
            }
        }

        await stopCapture(clearSessionState: false)
        guard restartGeneration == self.restartGeneration else {
            MirageLogger.capture("event=restart_canceled reason=stream_shutdown source=\(reason)")
            return
        }

        let resolvedConfig = await resolveCaptureTargetsForRestart(config: config, mode: mode)
        captureSessionConfig = resolvedConfig
        guard restartGeneration == self.restartGeneration else {
            MirageLogger.capture("event=restart_canceled reason=stream_shutdown source=\(reason)")
            return
        }

        do {
            switch mode {
            case .window:
                guard let window = resolvedConfig.window, let application = resolvedConfig.application else {
                    MirageLogger.error(.capture, "Capture restart failed: missing window/application")
                    break
                }
                try await startCapture(
                    window: window,
                    application: application,
                    display: resolvedConfig.display,
                    outputScale: resolvedConfig.outputScale,
                    onFrame: onFrame,
                    onAudio: onAudio,
                    audioChannelCount: resolvedConfig.audioChannelCount
                )
            case .display:
                try await startDisplayCapture(
                    display: resolvedConfig.display,
                    resolution: resolvedConfig.resolution,
                    sourceRect: resolvedConfig.sourceRect,
                    destinationRect: resolvedConfig.destinationRect,
                    contentWindowID: resolvedConfig.windowID,
                    includedWindows: resolvedConfig.includedWindows,
                    excludedWindows: resolvedConfig.excludedWindows,
                    showsCursor: resolvedConfig.showsCursor,
                    onFrame: onFrame,
                    onAudio: onAudio,
                    audioChannelCount: resolvedConfig.audioChannelCount
                )
            }
            markCaptureRestartKeyframeRequested(
                restartStreak: activeRestartStreak,
                shouldEscalateRecovery: shouldEscalateRecovery
            )
            MirageLogger
                .capture(
                    "event=restart_complete reason=\(reason) streak=\(activeRestartStreak) mode=\(mode == .display ? "display" : "window")"
                )
        } catch {
            let nsError = error as NSError
            let isStaleWindowOrDisplay = nsError.domain == "CoreGraphicsErrorDomain" && nsError.code == 1003
            let isTransientSCKitError = nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3818
            if isStaleWindowOrDisplay {
                MirageLogger.capture("Capture restart aborted (stale window/display ID): \(error)")
            } else if isTransientSCKitError {
                MirageLogger.capture("Capture restart deferred (transient SCKit error -3818): \(error)")
                scheduleCaptureRestart(reason: "sck_transient_retry", debounce: 1.0)
                return
            } else {
                MirageLogger.error(.capture, error: error, message: "Capture restart failed: ")
            }
            captureSessionConfig = nil
            captureMode = nil
            capturedFrameHandler = nil
            capturedAudioHandler = nil
            pendingKeyframeRequest = nil
            restartStreak = 0
            lastRestartAttemptTime = 0
        }
    }
}
#endif
