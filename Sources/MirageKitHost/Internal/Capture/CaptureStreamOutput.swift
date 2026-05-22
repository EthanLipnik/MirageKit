//
//  CaptureStreamOutput.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//

import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

/// ScreenCaptureKit output delegate that normalizes video/audio samples and monitors capture health.
final class CaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    /// Callback that receives renderable video frames.
    let onFrame: @Sendable (CapturedFrame) -> Void
    /// Callback that receives audio buffers when audio capture is enabled.
    var onAudio: (@Sendable (CapturedAudioBuffer) -> Void)?
    /// Protects audio-handler swaps from concurrent SCK callbacks.
    let audioHandlerLock = NSLock()
    /// Callback used to request a recovery keyframe after capture stalls or discontinuities.
    let onKeyframeRequest: @Sendable (KeyframeRequestReason) -> Void
    /// Callback used to report soft and hard capture stalls.
    let onCaptureStall: @Sendable (StallSignal) -> Void
    /// Optional admission gate that can drop frames while the stream is intentionally throttled.
    let shouldDropFrame: (@Sendable () -> Bool)?
    /// Whether frame metadata should include detailed dirty-rect and display timing fields.
    let usesDetailedMetadata: Bool
    /// Whether SCFrameStatus counters should be tracked for diagnostics.
    let tracksFrameStatus: Bool
    /// Number of frames emitted to the host pipeline.
    var frameCount: UInt64 = 0
    /// Number of idle frames skipped before delivery.
    var skippedIdleFrames: UInt64 = 0

    /// Callback duration total for the current diagnostics window.
    var callbackDurationTotalMs: Double = 0
    /// Maximum callback duration for the current diagnostics window.
    var callbackDurationMaxMs: Double = 0
    /// Callback sample count for the current diagnostics window.
    var callbackSampleCount: UInt64 = 0
    /// Lifetime callback duration total.
    var callbackDurationTotalCumulativeMs: Double = 0
    /// Lifetime maximum callback duration.
    var callbackDurationMaxCumulativeMs: Double = 0
    /// Lifetime callback sample count.
    var callbackSampleCountCumulative: UInt64 = 0
    /// Whether the current stall episode has already emitted a soft signal.
    var softStallSignaled: Bool = false
    /// Whether the current stall episode has already emitted a hard signal.
    var hardStallSignaled: Bool = false
    /// Last wall-clock time a stall signal was emitted.
    var lastStallTime: CFAbsoluteTime = 0
    /// Last delivered content rect, used to detect geometry changes.
    var lastContentRect: CGRect = .zero

    /// Timer that detects capture gaps when SCK pauses during menus, drags, or window transitions.
    var watchdogTimer: DispatchSourceTimer?
    /// Queue that runs watchdog checks off the SCK callback path.
    let watchdogQueue = DispatchQueue(label: "com.mirage.capture.watchdog", qos: .userInteractive)
    /// Host window ID being captured, or zero for display captures.
    var windowID: CGWindowID = 0
    /// Last time a frame was emitted to the host pipeline.
    var lastDeliveredFrameTime: CFAbsoluteTime = 0
    /// Last time SCK produced a complete frame sample.
    var lastCompleteFrameTime: CFAbsoluteTime = 0
    /// Gap duration before capture enters fallback mode.
    var frameGapThreshold: CFAbsoluteTime
    /// Gap duration before a soft stall signal is emitted.
    var softStallThreshold: CFAbsoluteTime
    /// Gap duration before a hard restart signal is emitted.
    var hardRestartThreshold: CFAbsoluteTime
    /// Target frame rate used for cadence admission and diagnostics.
    var targetFrameRate: Double
    /// Protects runtime capture expectation updates.
    let expectationLock = NSLock()
    /// Protects delivery timestamp and stall state updates.
    let deliveryStateLock = NSLock()
    let telemetryLifetimeStartTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    var telemetryWindowStartTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    var rawScreenCallbackCountWindow: UInt64 = 0
    var validScreenSampleCountWindow: UInt64 = 0
    var renderableScreenSampleCountWindow: UInt64 = 0
    var completeFrameCountWindow: UInt64 = 0
    var idleFrameCountWindow: UInt64 = 0
    var blankFrameCountWindow: UInt64 = 0
    var suspendedFrameCountWindow: UInt64 = 0
    var startedFrameCountWindow: UInt64 = 0
    var stoppedFrameCountWindow: UInt64 = 0
    var cadenceAdmittedFrameCountWindow: UInt64 = 0
    var deliveredFrameCountWindow: UInt64 = 0
    var rawScreenCallbackCountCumulative: UInt64 = 0
    var validScreenSampleCountCumulative: UInt64 = 0
    var renderableScreenSampleCountCumulative: UInt64 = 0
    var completeFrameCountCumulative: UInt64 = 0
    var idleFrameCountCumulative: UInt64 = 0
    var blankFrameCountCumulative: UInt64 = 0
    var suspendedFrameCountCumulative: UInt64 = 0
    var startedFrameCountCumulative: UInt64 = 0
    var stoppedFrameCountCumulative: UInt64 = 0
    var cadenceAdmittedFrameCountCumulative: UInt64 = 0
    var deliveredFrameCountCumulative: UInt64 = 0
    var cadenceOriginPresentationTime: Double = 0
    var lastCadenceAdmittedSlotIndex: Int64 = -1
    var cadenceDropCount: UInt64 = 0
    var cadenceDropTotalCount: UInt64 = 0
    var cadencePassCount: UInt64 = 0
    var cadenceSkewTotalMs: Double = 0
    var cadenceSkewSampleCount: UInt64 = 0
    var cadenceMetrics = CaptureCadenceMetricsTracker()

    var admissionDropCount: UInt64 = 0
    var admissionDropTotalCount: UInt64 = 0
    let poolLogLock = NSLock()

    /// Whether capture entered fallback mode during the current gap episode.
    var wasInFallbackMode: Bool = false
    /// Wall-clock time when fallback mode began.
    var fallbackStartTime: CFAbsoluteTime = 0
    /// Protects fallback mode state.
    let fallbackLock = NSLock()
    /// Protects startup readiness state gathered from early SCK samples.
    let startupReadinessLock = NSLock()
    /// Startup readiness classifier for blank/suspended/complete frame progress.
    var startupReadinessState = CaptureStartupReadinessState()

    init(
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onAudio: (@Sendable (CapturedAudioBuffer) -> Void)? = nil,
        onKeyframeRequest: @escaping @Sendable (KeyframeRequestReason) -> Void,
        onCaptureStall: @escaping @Sendable (StallSignal) -> Void,
        shouldDropFrame: (@Sendable () -> Bool)? = nil,
        windowID: CGWindowID = 0,
        usesDetailedMetadata: Bool = false,
        tracksFrameStatus: Bool = true,
        frameGapThreshold: CFAbsoluteTime = 0.100,
        softStallThreshold: CFAbsoluteTime = 1.0,
        hardRestartThreshold: CFAbsoluteTime? = nil,
        expectedFrameRate: Double = 0,
        targetFrameRate: Int = 0
    ) {
        self.onFrame = onFrame
        self.onAudio = onAudio
        self.onKeyframeRequest = onKeyframeRequest
        self.onCaptureStall = onCaptureStall
        self.shouldDropFrame = shouldDropFrame
        self.windowID = windowID
        self.usesDetailedMetadata = usesDetailedMetadata
        self.tracksFrameStatus = tracksFrameStatus
        self.frameGapThreshold = frameGapThreshold
        self.softStallThreshold = softStallThreshold
        self.hardRestartThreshold = hardRestartThreshold ?? softStallThreshold
        self.targetFrameRate = Double(max(0, targetFrameRate))
        cadenceMetrics = CaptureCadenceMetricsTracker(
            expectedFrameRate: expectedFrameRate,
            targetFrameRate: Double(max(0, targetFrameRate))
        )
        super.init()
        startWatchdogTimer()
    }

    deinit {
        stopWatchdogTimer()
    }

    func setAudioHandler(_ handler: (@Sendable (CapturedAudioBuffer) -> Void)?) {
        audioHandlerLock.lock()
        defer { audioHandlerLock.unlock() }
        onAudio = handler
    }

    /// Starts the watchdog timer that checks for frame gaps.
    private func startWatchdogTimer() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        let initialDelayMs = expectationLock.withLock { max(50, Int(frameGapThreshold * 1000)) }
        timer.schedule(deadline: .now() + .milliseconds(initialDelayMs), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.checkForFrameGap()
        }
        timer.resume()
        watchdogTimer = timer
        let thresholdMs = expectationLock.withLock { Int(frameGapThreshold * 1000) }
        MirageLogger.capture("Frame gap watchdog started (\(thresholdMs)ms threshold, 50ms check interval)")
    }

    /// Stops the capture gap watchdog.
    func stopWatchdogTimer() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    /// Current startup readiness derived from early frame statuses.
    var captureStartupReadiness: DisplayCaptureStartupReadiness {
        startupReadinessLock.withLock { startupReadinessState.readiness }
    }

    /// Whether any startup sample has been observed from SCK.
    var hasObservedStartupSample: Bool {
        startupReadinessLock.withLock { startupReadinessState.hasObservedSample }
    }

    func updateExpectations(
        frameRate: Int,
        gapThreshold: CFAbsoluteTime,
        softStallThreshold: CFAbsoluteTime,
        hardRestartThreshold: CFAbsoluteTime? = nil,
        targetFrameRate: Int
    ) {
        expectationLock.withLock {
            self.targetFrameRate = Double(max(0, targetFrameRate))
            frameGapThreshold = gapThreshold
            self.softStallThreshold = softStallThreshold
            self.hardRestartThreshold = hardRestartThreshold ?? softStallThreshold
            cadenceOriginPresentationTime = 0
            lastCadenceAdmittedSlotIndex = -1
            cadencePassCount = 0
            cadenceSkewTotalMs = 0
            cadenceSkewSampleCount = 0
        }
        poolLogLock.withLock {
            cadenceMetrics.updateFrameRates(
                expectedFrameRate: Double(frameRate),
                targetFrameRate: Double(max(0, targetFrameRate))
            )
        }
        deliveryStateLock.withLock {
            softStallSignaled = false
            hardStallSignaled = false
        }
        stopWatchdogTimer()
        startWatchdogTimer()
    }

    func updateWindowID(_ windowID: CGWindowID) {
        expectationLock.withLock {
            self.windowID = windowID
        }
        if windowID == 0 {
            lastContentRect = .zero
        }
    }

    /// Reset fallback state (called during dimension changes)
    func clearCache() {
        fallbackLock.lock()
        do {
            defer { fallbackLock.unlock() }
            wasInFallbackMode = false
            fallbackStartTime = 0
        }
        lastContentRect = .zero
        expectationLock.withLock {
            cadenceOriginPresentationTime = 0
            lastCadenceAdmittedSlotIndex = -1
            cadencePassCount = 0
            cadenceSkewTotalMs = 0
            cadenceSkewSampleCount = 0
        }
        MirageLogger.capture("Reset fallback state for resize")
    }
}

#endif
