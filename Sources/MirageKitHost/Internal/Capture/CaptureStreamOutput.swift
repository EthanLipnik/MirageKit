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
import os
import MirageKit

#if os(macOS)
import AppKit
import AudioToolbox
import ScreenCaptureKit

/// Stream output delegate
final class CaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    enum KeyframeRequestReason: Sendable {
        case fallbackResume
    }

    enum StallStage: String, Sendable {
        case soft
        case hard
        case resumed
    }

    struct StallSignal: Sendable {
        let stage: StallStage
        let message: String
        let gapMs: String
        let softThresholdMs: String
        let hardThresholdMs: String
        let restartEligible: Bool
    }

    struct TelemetrySnapshot: Sendable, Equatable {
        let rawScreenCallbackCount: UInt64
        let validScreenSampleCount: UInt64
        let renderableScreenSampleCount: UInt64
        let completeFrameCount: UInt64
        let idleFrameCount: UInt64
        let blankFrameCount: UInt64
        let suspendedFrameCount: UInt64
        let startedFrameCount: UInt64
        let stoppedFrameCount: UInt64
        let cadenceAdmittedFrameCount: UInt64
        let deliveredFrameCount: UInt64
        let callbackDurationTotalMs: Double
        let callbackDurationMaxMs: Double
        let callbackSampleCount: UInt64
        let cadenceDropCount: UInt64
        let admissionDropCount: UInt64
    }

    struct CadenceDecision: Sendable, Equatable {
        let shouldDrop: Bool
        let originPresentationTime: Double?
        let admittedSlotIndex: Int64
        let expectedPresentationTime: Double?
    }

    private let onFrame: @Sendable (CapturedFrame) -> Void
    private let onAudio: (@Sendable (CapturedAudioBuffer) -> Void)?
    private let onKeyframeRequest: @Sendable (KeyframeRequestReason) -> Void
    private let onCaptureStall: @Sendable (StallSignal) -> Void
    private let shouldDropFrame: (@Sendable () -> Bool)?
    private let usesDetailedMetadata: Bool
    private let tracksFrameStatus: Bool
    private var frameCount: UInt64 = 0
    private var skippedIdleFrames: UInt64 = 0

    // DIAGNOSTIC: Track all frame statuses to debug drag/menu freeze issue
    private var statusCounts: [Int: UInt64] = [:]
    private var lastStatusLogTime: CFAbsoluteTime = 0
    private var lastFrameTime: CFAbsoluteTime = 0
    private var maxFrameGap: CFAbsoluteTime = 0
    private var lastFPSLogTime: CFAbsoluteTime = 0
    private var presentationWindowCount: UInt64 = 0
    private var presentationWindowStartTime: Double = 0
    private var deliveredFrameWindowCount: UInt64 = 0
    private var deliveredCompleteWindowCount: UInt64 = 0
    private var deliveredIdleWindowCount: UInt64 = 0
    private var callbackDurationTotalMs: Double = 0
    private var callbackDurationMaxMs: Double = 0
    private var callbackSampleCount: UInt64 = 0
    private var callbackDurationTotalCumulativeMs: Double = 0
    private var callbackDurationMaxCumulativeMs: Double = 0
    private var callbackSampleCountCumulative: UInt64 = 0
    private var lastCallbackLogTime: CFAbsoluteTime = 0
    private var audioBufferCount: UInt64 = 0
    private var lastAudioLogTime: CFAbsoluteTime = 0
    private var softStallSignaled: Bool = false
    private var hardStallSignaled: Bool = false
    private var lastStallTime: CFAbsoluteTime = 0
    private var lastContentRect: CGRect = .zero
    private var statusBurstDeadline: CFAbsoluteTime = 0

    // Frame gap watchdog: when SCK stops delivering frames (during menus/drags),
    // mark fallback mode so resume can trigger a keyframe request
    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.mirage.capture.watchdog", qos: .userInteractive)
    private var windowID: CGWindowID = 0
    private var lastDeliveredFrameTime: CFAbsoluteTime = 0
    private var lastCompleteFrameTime: CFAbsoluteTime = 0
    private var frameGapThreshold: CFAbsoluteTime
    private var softStallThreshold: CFAbsoluteTime
    private var hardRestartThreshold: CFAbsoluteTime
    private var expectedFrameRate: Double
    private var targetFrameRate: Double
    private let expectationLock = NSLock()
    private let deliveryStateLock = NSLock()
    private var rawFrameWindowCount: UInt64 = 0
    private var rawFrameWindowStartTime: CFAbsoluteTime = 0
    private var rawScreenCallbackCountCumulative: UInt64 = 0
    private var validScreenSampleCountCumulative: UInt64 = 0
    private var renderableScreenSampleCountCumulative: UInt64 = 0
    private var completeFrameCountCumulative: UInt64 = 0
    private var idleFrameCountCumulative: UInt64 = 0
    private var blankFrameCountCumulative: UInt64 = 0
    private var suspendedFrameCountCumulative: UInt64 = 0
    private var startedFrameCountCumulative: UInt64 = 0
    private var stoppedFrameCountCumulative: UInt64 = 0
    private var cadenceAdmittedFrameCountCumulative: UInt64 = 0
    private var deliveredFrameCountCumulative: UInt64 = 0
    private var cadenceOriginPresentationTime: Double = 0
    private var lastCadenceAdmittedPresentationTime: Double = 0
    private var lastCadenceAdmittedSlotIndex: Int64 = -1
    private var cadenceDropCount: UInt64 = 0
    private var cadenceDropTotalCount: UInt64 = 0
    private var cadencePassCount: UInt64 = 0
    private var cadenceSkewTotalMs: Double = 0
    private var cadenceSkewSampleCount: UInt64 = 0
    private var lastCadenceLogTime: CFAbsoluteTime = 0

    // Menu tracking/alerts can pause window capture for several seconds.
    // Use a longer stall threshold for window-based capture to avoid restart loops.
    private let windowStallThreshold: CFAbsoluteTime = 8.0
    private let displayStallThreshold: CFAbsoluteTime = 0.6

    private var admissionDropCount: UInt64 = 0
    private var admissionDropTotalCount: UInt64 = 0
    private var lastAdmissionLogTime: CFAbsoluteTime = 0
    private let poolLogLock = NSLock()

    // Track if we've been in fallback mode - when SCK resumes, we may need a keyframe
    // to prevent decode errors from reference frame discontinuity
    private var wasInFallbackMode: Bool = false
    private var fallbackStartTime: CFAbsoluteTime = 0 // When fallback mode started
    private let fallbackLock = NSLock()
    private let startupReadinessLock = NSLock()
    private var startupReadinessState = CaptureStartupReadinessState()

    /// Only request keyframe if fallback lasted longer than this threshold.
    /// Short fallback blips are common during menu tracking and focus churn and
    /// forcing a keyframe for each one can overload multi-stream app sessions.
    private let keyframeThreshold: CFAbsoluteTime = 1.0
    /// Scales fallback-resume keyframe requests with expected frame-gap tolerance.
    /// Low-FPS passive streams should require a much longer fallback duration before
    /// forcing expensive keyframes.
    private let fallbackResumeKeyframeGapMultiplier: CFAbsoluteTime = 2.5

    private struct CaptureStartupReadinessState {
        var hasObservedSample = false
        var hasUsableFrame = false
        var hasIdleFrame = false
        var blankOrSuspendedCount: UInt64 = 0
        var hasLoggedBlankOrSuspended = false
        var hasLoggedLifecycleSample = false

        var readiness: DisplayCaptureStartupReadiness {
            if hasUsableFrame { return .usableFrameSeen }
            if hasIdleFrame { return .idleFrameSeen }
            if blankOrSuspendedCount > 0 { return .blankOrSuspendedOnly }
            return .noScreenSamples
        }
    }

    init(
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onAudio: (@Sendable (CapturedAudioBuffer) -> Void)? = nil,
        onKeyframeRequest: @escaping @Sendable (KeyframeRequestReason) -> Void,
        onCaptureStall: @escaping @Sendable (StallSignal) -> Void = { _ in },
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
        self.expectedFrameRate = expectedFrameRate
        self.targetFrameRate = Double(max(0, targetFrameRate))
        super.init()
        startWatchdogTimer()
    }

    deinit {
        stopWatchdogTimer()
    }

    /// Start the watchdog timer that checks for frame gaps
    private func startWatchdogTimer() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        // Check every 50ms for fallback during drag operations
        // Initial delay matches frameGapThreshold
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

    func stopWatchdogTimer() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    func captureStartupReadiness() -> DisplayCaptureStartupReadiness {
        startupReadinessLock.withLock { startupReadinessState.readiness }
    }

    func hasObservedStartupSample() -> Bool {
        startupReadinessLock.withLock { startupReadinessState.hasObservedSample }
    }

    func displayStartupReadiness() -> DisplayCaptureStartupReadiness {
        captureStartupReadiness()
    }

    func hasObservedDisplayStartupSample() -> Bool {
        hasObservedStartupSample()
    }

    func updateExpectations(
        frameRate: Int,
        gapThreshold: CFAbsoluteTime,
        softStallThreshold: CFAbsoluteTime,
        hardRestartThreshold: CFAbsoluteTime? = nil,
        targetFrameRate: Int
    ) {
        expectationLock.withLock {
            expectedFrameRate = Double(frameRate)
            self.targetFrameRate = Double(max(0, targetFrameRate))
            frameGapThreshold = gapThreshold
            self.softStallThreshold = softStallThreshold
            self.hardRestartThreshold = hardRestartThreshold ?? softStallThreshold
            cadenceOriginPresentationTime = 0
            lastCadenceAdmittedPresentationTime = 0
            lastCadenceAdmittedSlotIndex = -1
            cadencePassCount = 0
            cadenceSkewTotalMs = 0
            cadenceSkewSampleCount = 0
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

    func telemetrySnapshot() -> TelemetrySnapshot {
        return poolLogLock.withLock {
            TelemetrySnapshot(
                rawScreenCallbackCount: rawScreenCallbackCountCumulative,
                validScreenSampleCount: validScreenSampleCountCumulative,
                renderableScreenSampleCount: renderableScreenSampleCountCumulative,
                completeFrameCount: completeFrameCountCumulative,
                idleFrameCount: idleFrameCountCumulative,
                blankFrameCount: blankFrameCountCumulative,
                suspendedFrameCount: suspendedFrameCountCumulative,
                startedFrameCount: startedFrameCountCumulative,
                stoppedFrameCount: stoppedFrameCountCumulative,
                cadenceAdmittedFrameCount: cadenceAdmittedFrameCountCumulative,
                deliveredFrameCount: deliveredFrameCountCumulative,
                callbackDurationTotalMs: callbackDurationTotalCumulativeMs,
                callbackDurationMaxMs: callbackDurationMaxCumulativeMs,
                callbackSampleCount: callbackSampleCountCumulative,
                cadenceDropCount: cadenceDropTotalCount,
                admissionDropCount: admissionDropTotalCount
            )
        }
    }

    /// Reset fallback state (called during dimension changes)
    func clearCache() {
        fallbackLock.lock()
        wasInFallbackMode = false
        fallbackStartTime = 0
        fallbackLock.unlock()
        lastContentRect = .zero
        expectationLock.withLock {
            cadenceOriginPresentationTime = 0
            lastCadenceAdmittedPresentationTime = 0
            lastCadenceAdmittedSlotIndex = -1
            cadencePassCount = 0
            cadenceSkewTotalMs = 0
            cadenceSkewSampleCount = 0
        }
        MirageLogger.capture("Reset fallback state for resize")
    }

    private func fullBufferContentRect(
        bufferWidth: Int,
        bufferHeight: Int
    ) -> CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(bufferWidth), height: CGFloat(bufferHeight))
    }

    private func normalizedContentRect(
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
            // Display capture can temporarily pause under compositor pressure.
            // Keep restart responsiveness while preventing pathological sub-600ms loops.
            let minDisplayThreshold = max(0.6, min(displayStallThreshold, 1.0))
            let maxDisplayThreshold: CFAbsoluteTime = 4.0
            return min(max(configuredStallLimit, minDisplayThreshold), maxDisplayThreshold)
        }
        return max(configuredStallLimit, windowStallThreshold)
    }

    /// Check if SCK has stopped delivering frames and trigger fallback
    private func checkForFrameGap() {
        let now = CFAbsoluteTimeGetCurrent()
        let (lastDeliveredFrameTime, lastCompleteFrameTime) = deliveryStateLock.withLock {
            (self.lastDeliveredFrameTime, self.lastCompleteFrameTime)
        }
        guard lastDeliveredFrameTime > 0 else { return }

        let (gapThreshold, configuredSoftStallLimit, configuredHardRestartLimit) = expectationLock.withLock {
            (frameGapThreshold, softStallThreshold, hardRestartThreshold)
        }
        let softLimit = Self.resolvedStallLimit(
            windowID: windowID,
            configuredStallLimit: configuredSoftStallLimit,
            displayStallThreshold: displayStallThreshold,
            windowStallThreshold: windowStallThreshold
        )
        let hardLimit = max(softLimit, configuredHardRestartLimit)
        let recentActivityWindow = max(2.0, min(6.0, hardLimit * 2.0))
        let anyGap = now - lastDeliveredFrameTime
        let completeGap = lastCompleteFrameTime > 0 ? now - lastCompleteFrameTime : anyGap
        let useCompleteGap = lastCompleteFrameTime > 0 && completeGap <= recentActivityWindow
        let gap = useCompleteGap ? completeGap : anyGap
        guard gap > gapThreshold else { return }

        // SCK has stopped delivering - mark fallback mode
        markFallbackModeForGap()

        let gapMs = (gap * 1000).formatted(.number.precision(.fractionLength(1)))
        let softMs = (softLimit * 1000).formatted(.number.precision(.fractionLength(1)))
        let hardMs = (hardLimit * 1000).formatted(.number.precision(.fractionLength(1)))
        let completeGapMs = (completeGap * 1000).formatted(.number.precision(.fractionLength(1)))
        let anyGapMs = (anyGap * 1000).formatted(.number.precision(.fractionLength(1)))
        let mode = useCompleteGap ? "content" : "any"

        var shouldEmitSoftStall = false
        if gap > softLimit {
            deliveryStateLock.withLock {
                if !softStallSignaled {
                    softStallSignaled = true
                    shouldEmitSoftStall = true
                }
            }
        }
        if shouldEmitSoftStall {
            onCaptureStall(
                StallSignal(
                    stage: .soft,
                    message: "frame gap \(gapMs)ms (complete \(completeGapMs)ms, any \(anyGapMs)ms, mode=\(mode))",
                    gapMs: gapMs,
                    softThresholdMs: softMs,
                    hardThresholdMs: hardMs,
                    restartEligible: false
                )
            )
        }

        var shouldEmitHardStall = false
        if gap > hardLimit {
            deliveryStateLock.withLock {
                if !hardStallSignaled, now - lastStallTime > hardLimit {
                    hardStallSignaled = true
                    lastStallTime = now
                    shouldEmitHardStall = true
                }
            }
        }
        if shouldEmitHardStall {
            onCaptureStall(
                StallSignal(
                    stage: .hard,
                    message: "frame gap \(gapMs)ms (complete \(completeGapMs)ms, any \(anyGapMs)ms, mode=\(mode))",
                    gapMs: gapMs,
                    softThresholdMs: softMs,
                    hardThresholdMs: hardMs,
                    restartEligible: true
                )
            )
        }
    }

    /// Mark fallback mode when SCK stops delivering frames.
    private func markFallbackModeForGap() {
        // Mark that we're in fallback mode and record start time
        fallbackLock.lock()
        if wasInFallbackMode {
            fallbackLock.unlock()
            return
        }
        fallbackStartTime = CFAbsoluteTimeGetCurrent()
        wasInFallbackMode = true
        fallbackLock.unlock()
    }

    private func updateDeliveryState(captureTime: CFAbsoluteTime, isComplete: Bool) {
        deliveryStateLock.withLock {
            lastDeliveredFrameTime = captureTime
            softStallSignaled = false
            hardStallSignaled = false
            if isComplete {
                lastCompleteFrameTime = captureTime
            }
        }
        if isComplete {
            handleFallbackResumeIfNeeded()
        }
    }

    func isRecentlyRecovered(within window: CFAbsoluteTime) -> Bool {
        let graceWindow = max(0, window)
        let now = CFAbsoluteTimeGetCurrent()
        let inFallback = fallbackLock.withLock { wasInFallbackMode }
        guard !inFallback else { return false }
        let lastDelivered = deliveryStateLock.withLock { lastDeliveredFrameTime }
        guard lastDelivered > 0 else { return false }
        return now - lastDelivered <= graceWindow
    }

    private func handleFallbackResumeIfNeeded() {
        // Only request keyframe if fallback lasted long enough to cause decode issues.
        fallbackLock.lock()
        guard wasInFallbackMode else {
            fallbackLock.unlock()
            return
        }
        let fallbackDuration = CFAbsoluteTimeGetCurrent() - fallbackStartTime
        wasInFallbackMode = false
        fallbackLock.unlock()

        let fallbackMs = Int((fallbackDuration * 1000).rounded())
        let gapThreshold = expectationLock.withLock { frameGapThreshold }
        let requiredDuration = Self.fallbackResumeKeyframeThreshold(
            frameGapThreshold: gapThreshold,
            minimumThreshold: keyframeThreshold,
            multiplier: fallbackResumeKeyframeGapMultiplier
        )
        let requiredMs = Int((requiredDuration * 1000).rounded())
        let fallbackMsText = "\(fallbackMs)"
        let requiredMsText = "\(requiredMs)"
        onCaptureStall(
            StallSignal(
                stage: .resumed,
                message: "stall resumed after \(fallbackMs)ms",
                gapMs: fallbackMsText,
                softThresholdMs: requiredMsText,
                hardThresholdMs: requiredMsText,
                restartEligible: false
            )
        )
        if fallbackDuration > requiredDuration {
            onKeyframeRequest(.fallbackResume)
            MirageLogger
                .capture(
                    "event=stall_resumed durationMs=\(fallbackMs) keyframe=scheduled thresholdMs=\(requiredMs)"
                )
        } else {
            MirageLogger
                .capture(
                    "event=stall_resumed durationMs=\(fallbackMs) keyframe=skipped thresholdMs=\(requiredMs)"
                )
        }
    }

    nonisolated static func fallbackResumeKeyframeThreshold(
        frameGapThreshold: CFAbsoluteTime,
        minimumThreshold: CFAbsoluteTime = 1.0,
        multiplier: CFAbsoluteTime = 2.5
    ) -> CFAbsoluteTime {
        let safeMultiplier = max(1.0, multiplier)
        let safeGap = max(0, frameGapThreshold)
        return max(minimumThreshold, safeGap * safeMultiplier)
    }

    nonisolated static func shouldRequestFallbackResumeKeyframe(
        fallbackDuration: CFAbsoluteTime,
        frameGapThreshold: CFAbsoluteTime,
        minimumThreshold: CFAbsoluteTime = 1.0,
        multiplier: CFAbsoluteTime = 2.5
    ) -> Bool {
        fallbackDuration > fallbackResumeKeyframeThreshold(
            frameGapThreshold: frameGapThreshold,
            minimumThreshold: minimumThreshold,
            multiplier: multiplier
        )
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let diagnosticsEnabled = MirageLogger.isEnabled(.capture)
        let callbackStartTime = CFAbsoluteTimeGetCurrent()
        defer {
            let durationMs = (CFAbsoluteTimeGetCurrent() - callbackStartTime) * 1000
            recordCallbackDuration(durationMs)
        }

        let wallTime = CFAbsoluteTimeGetCurrent() // Timing: when SCK delivered the frame
        let captureTime = wallTime

        if type == .audio {
            emitAudio(sampleBuffer: sampleBuffer)
            return
        }

        guard type == .screen else { return }
        recordRawScreenCallback()

        // DIAGNOSTIC: Track frame delivery gaps to detect drag/menu freeze
        if lastFrameTime > 0 {
            let gap = captureTime - lastFrameTime
            if gap > 0.1 { // Log gaps > 100ms
                let gapMs = (gap * 1000).formatted(.number.precision(.fractionLength(1)))
                MirageLogger.capture("FRAME GAP: \(gapMs)ms since last frame")
                statusBurstDeadline = max(statusBurstDeadline, captureTime + 2.0)
            }
            if gap > maxFrameGap {
                maxFrameGap = gap
                if maxFrameGap > 0.2 { // Only log significant new records
                    let gapMs = (maxFrameGap * 1000).formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.capture("NEW MAX FRAME GAP: \(gapMs)ms")
                }
            }
        }
        lastFrameTime = captureTime

        if diagnosticsEnabled {
            rawFrameWindowCount += 1
            if rawFrameWindowStartTime == 0 { rawFrameWindowStartTime = captureTime } else if captureTime - rawFrameWindowStartTime > 2.0 {
                let elapsed = captureTime - rawFrameWindowStartTime
                let rawFPS = Double(rawFrameWindowCount) / elapsed
                let rawFPSText = rawFPS.formatted(.number.precision(.fractionLength(1)))
                let targetText = expectedFrameRate.formatted(.number.precision(.fractionLength(1)))
                MirageLogger.capture("Capture raw fps: \(rawFPSText) (target=\(targetText))")
                rawFrameWindowCount = 0
                rawFrameWindowStartTime = captureTime
            }
        }

        let attachments =
            (CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]])?.first
        let status = resolvedFrameStatus(from: attachments)
        let isValidSampleBuffer = CMSampleBufferIsValid(sampleBuffer)
        if let status {
            noteCaptureStartupSample(status: status)
            recordFrameStatus(status)
        } else if tracksFrameStatus, windowID == 0, isValidSampleBuffer {
            noteObservedStartupSample()
        }

        // Validate the sample buffer
        guard isValidSampleBuffer,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        recordValidScreenSample()

        if diagnosticsEnabled {
            updatePresentationFPS(presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }

        if !tracksFrameStatus {
            if status == nil {
                noteCaptureStartupSample(status: .complete)
                recordFrameStatus(.complete)
            }
            recordRenderableScreenSample()
            updateDeliveryState(captureTime: captureTime, isComplete: true)
            if diagnosticsEnabled {
                deliveredFrameWindowCount += 1
                if lastFPSLogTime == 0 { lastFPSLogTime = captureTime } else if captureTime - lastFPSLogTime > 2.0 {
                    let elapsed = captureTime - lastFPSLogTime
                    let fps = Double(deliveredFrameWindowCount) / elapsed
                    let fpsText = fps.formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.capture("Capture fps: \(fpsText)")
                    deliveredFrameWindowCount = 0
                    lastFPSLogTime = captureTime
                }
            }

            if let shouldDropFrame, shouldDropFrame() {
                logAdmissionDrop()
                return
            }

            let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
            let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
            frameCount += 1
            if frameCount == 1 || frameCount % 600 == 0 { MirageLogger.capture("Frame \(frameCount): \(bufferWidth)x\(bufferHeight)") }

            let frameInfo = CapturedFrameInfo(
                contentRect: CGRect(x: 0, y: 0, width: CGFloat(bufferWidth), height: CGFloat(bufferHeight)),
                dirtyPercentage: 100,
                isIdleFrame: false
            )
            emitFrame(
                sampleBuffer: sampleBuffer,
                sourcePixelBuffer: pixelBuffer,
                frameInfo: frameInfo,
                captureTime: captureTime,
                attachments: attachments
            )
            return
        }

        // Check SCFrameStatus - track all statuses for diagnostics
        var isIdleFrame = false
        if let status {
            let resolvedStatus = status

            // DIAGNOSTIC: Track status distribution
            if diagnosticsEnabled {
                statusCounts[resolvedStatus.rawValue, default: 0] += 1
                let logInterval: CFAbsoluteTime = captureTime <= statusBurstDeadline ? 0.5 : 2.0
                if captureTime - lastStatusLogTime > logInterval {
                    lastStatusLogTime = captureTime
                    let statusNames = statusCounts.map { key, count in
                        let name = switch SCFrameStatus(rawValue: key) {
                        case .idle: "idle"
                        case .complete: "complete"
                        case .blank: "blank"
                        case .suspended: "suspended"
                        case .started: "started"
                        case .stopped: "stopped"
                        default: "unknown(\(key))"
                        }
                        return "\(name):\(count)"
                    }.joined(separator: ", ")
                    MirageLogger.capture("Frame status distribution: [\(statusNames)]")
                    statusCounts.removeAll()
                }
            }

            // Allow idle frames through instead of filtering them out.
            if resolvedStatus == .idle {
                skippedIdleFrames += 1
                isIdleFrame = true
            }

            // Skip blank/suspended frames - these indicate actual capture issues.
            if resolvedStatus == .blank || resolvedStatus == .suspended { return }
        }

        let effectiveStatus = status ?? .complete
        if status == nil {
            noteCaptureStartupSample(status: effectiveStatus)
            recordFrameStatus(effectiveStatus)
        }
        guard effectiveStatus == .complete || effectiveStatus == .idle else { return }
        if effectiveStatus == .idle { isIdleFrame = true }
        recordRenderableScreenSample()

        updateDeliveryState(captureTime: captureTime, isComplete: effectiveStatus == .complete)
        if diagnosticsEnabled {
            deliveredFrameWindowCount += 1
            if effectiveStatus == .idle { deliveredIdleWindowCount += 1 } else {
                deliveredCompleteWindowCount += 1
            }
            if lastFPSLogTime == 0 { lastFPSLogTime = captureTime } else if captureTime - lastFPSLogTime > 2.0 {
                let elapsed = captureTime - lastFPSLogTime
                let fps = Double(deliveredFrameWindowCount) / elapsed
                let fpsText = fps.formatted(.number.precision(.fractionLength(1)))
                MirageLogger
                    .capture("Capture fps: \(fpsText) (complete=\(deliveredCompleteWindowCount), idle=\(deliveredIdleWindowCount))")
                deliveredFrameWindowCount = 0
                deliveredCompleteWindowCount = 0
                deliveredIdleWindowCount = 0
                lastFPSLogTime = captureTime
            }
        }

        if let shouldDropFrame, shouldDropFrame() {
            logAdmissionDrop()
            return
        }

        // Extract contentRect when detailed metadata is enabled. For display capture,
        // fast-path to full-buffer rect to minimize per-frame work.
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let fullRect = fullBufferContentRect(bufferWidth: bufferWidth, bufferHeight: bufferHeight)
        var contentRect = fullRect
        let shouldReuseCachedContentRect = windowID == 0
        if usesDetailedMetadata,
           !isIdleFrame,
           let attachments,
           let contentRectValue = attachments[.contentRect] {
            let scaleFactor: CGFloat = if let scale = attachments[.scaleFactor] as? CGFloat {
                scale
            } else if let scale = attachments[.scaleFactor] as? Double {
                CGFloat(scale)
            } else if let scale = attachments[.scaleFactor] as? NSNumber {
                CGFloat(scale.doubleValue)
            } else {
                1.0
            }
            let contentRectDict = contentRectValue as! CFDictionary
            if let rect = CGRect(dictionaryRepresentation: contentRectDict) {
                let scaledRect = CGRect(
                    x: rect.origin.x * scaleFactor,
                    y: rect.origin.y * scaleFactor,
                    width: rect.width * scaleFactor,
                    height: rect.height * scaleFactor
                )
                if let normalizedRect = normalizedContentRect(
                    scaledRect,
                    bufferWidth: bufferWidth,
                    bufferHeight: bufferHeight
                ) {
                    contentRect = normalizedRect
                    lastContentRect = normalizedRect
                } else if shouldReuseCachedContentRect, !lastContentRect.isEmpty {
                    contentRect = lastContentRect
                } else if !shouldReuseCachedContentRect {
                    MirageLogger.debug(
                        .capture,
                        "Discarding invalid window contentRect \(scaledRect) for buffer \(bufferWidth)x\(bufferHeight); using full-frame rect"
                    )
                }
            } else if shouldReuseCachedContentRect, !lastContentRect.isEmpty {
                contentRect = lastContentRect
            }
        } else if shouldReuseCachedContentRect, !lastContentRect.isEmpty {
            contentRect = lastContentRect
        }

        // Calculate dirty region statistics for diagnostics only.
        let totalPixels = bufferWidth * bufferHeight
        let dirtyPercentage: Float = if isIdleFrame {
            0
        } else if totalPixels > 0 {
            100
        } else {
            0
        }

        // Fallback: if contentRect is zero/invalid, use full buffer dimensions
        if contentRect.isEmpty { contentRect = fullRect }

        // Log frame dimensions periodically (first frame and every 10 seconds at 60fps)
        frameCount += 1
        if frameCount == 1 || frameCount % 600 == 0 { MirageLogger.capture("Frame \(frameCount): \(bufferWidth)x\(bufferHeight)") }

        // Create frame info with minimal capture metadata
        // Keyframe requests are now handled by StreamContext cadence, so don't flag here.
        let frameInfo = CapturedFrameInfo(
            contentRect: contentRect,
            dirtyPercentage: dirtyPercentage,
            isIdleFrame: isIdleFrame
        )

        emitFrame(
            sampleBuffer: sampleBuffer,
            sourcePixelBuffer: pixelBuffer,
            frameInfo: frameInfo,
            captureTime: captureTime,
            attachments: attachments
        )
    }

    private func noteCaptureStartupSample(status: SCFrameStatus) {
        var blankOrSuspendedStatusName: String?
        var lifecycleStatusName: String?
        startupReadinessLock.withLock {
            startupReadinessState.hasObservedSample = true
            switch status {
            case .complete:
                startupReadinessState.hasUsableFrame = true
            case .idle:
                startupReadinessState.hasIdleFrame = true
            case .blank:
                startupReadinessState.blankOrSuspendedCount &+= 1
                if windowID == 0, !startupReadinessState.hasLoggedBlankOrSuspended {
                    startupReadinessState.hasLoggedBlankOrSuspended = true
                    blankOrSuspendedStatusName = "blank"
                }
            case .suspended:
                startupReadinessState.blankOrSuspendedCount &+= 1
                if windowID == 0, !startupReadinessState.hasLoggedBlankOrSuspended {
                    startupReadinessState.hasLoggedBlankOrSuspended = true
                    blankOrSuspendedStatusName = "suspended"
                }
            case .started:
                if windowID == 0, !startupReadinessState.hasLoggedLifecycleSample {
                    startupReadinessState.hasLoggedLifecycleSample = true
                    lifecycleStatusName = "started"
                }
            case .stopped:
                if windowID == 0, !startupReadinessState.hasLoggedLifecycleSample {
                    startupReadinessState.hasLoggedLifecycleSample = true
                    lifecycleStatusName = "stopped"
                }
            default:
                break
            }
        }

        if let blankOrSuspendedStatusName {
            MirageLogger.capture(
                "Display startup sample status=\(blankOrSuspendedStatusName) while waiting for first usable frame"
            )
        }
        if let lifecycleStatusName {
            MirageLogger.capture(
                "Display startup lifecycle status=\(lifecycleStatusName) before first renderable frame"
            )
        }
    }

    private func noteObservedStartupSample() {
        startupReadinessLock.withLock {
            startupReadinessState.hasObservedSample = true
        }
    }

    private func resolvedFrameStatus(
        from attachments: [SCStreamFrameInfo: Any]?
    ) -> SCFrameStatus? {
        guard let attachments,
              let statusRawValue = attachments[.status] as? Int else {
            return nil
        }
        return SCFrameStatus(rawValue: statusRawValue)
    }

    private func updatePresentationFPS(presentationTime: CMTime) {
        guard presentationTime.isValid else { return }
        let seconds = CMTimeGetSeconds(presentationTime)
        guard seconds.isFinite, seconds >= 0 else { return }
        presentationWindowCount += 1
        if presentationWindowStartTime == 0 {
            presentationWindowStartTime = seconds
            return
        }
        let window = seconds - presentationWindowStartTime
        guard window > 2.0 else { return }
        let fps = Double(presentationWindowCount) / window
        let fpsText = fps.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.capture("Capture PTS fps: \(fpsText) (window \(window.formatted(.number.precision(.fractionLength(2))))s)")
        presentationWindowCount = 0
        presentationWindowStartTime = seconds
    }

    private func recordCallbackDuration(_ durationMs: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        poolLogLock.withLock {
            callbackDurationTotalMs += durationMs
            callbackDurationMaxMs = max(callbackDurationMaxMs, durationMs)
            callbackSampleCount += 1
            callbackDurationTotalCumulativeMs += durationMs
            callbackDurationMaxCumulativeMs = max(callbackDurationMaxCumulativeMs, durationMs)
            callbackSampleCountCumulative &+= 1
            guard MirageLogger.isEnabled(.capture) else { return }
            if lastCallbackLogTime == 0 {
                lastCallbackLogTime = now
                return
            }
            guard now - lastCallbackLogTime > 2.0 else { return }
            let avgMs = callbackSampleCount > 0 ? callbackDurationTotalMs / Double(callbackSampleCount) : 0
            let avgText = avgMs.formatted(.number.precision(.fractionLength(2)))
            let maxText = callbackDurationMaxMs.formatted(.number.precision(.fractionLength(2)))
            MirageLogger.capture("Capture callback: avg=\(avgText)ms max=\(maxText)ms")
            callbackDurationTotalMs = 0
            callbackDurationMaxMs = 0
            callbackSampleCount = 0
            lastCallbackLogTime = now
        }
    }

    private func recordRawScreenCallback() {
        poolLogLock.withLock {
            rawScreenCallbackCountCumulative &+= 1
        }
    }

    private func recordValidScreenSample() {
        poolLogLock.withLock {
            validScreenSampleCountCumulative &+= 1
        }
    }

    private func recordFrameStatus(_ status: SCFrameStatus) {
        poolLogLock.withLock {
            switch status {
            case .complete:
                completeFrameCountCumulative &+= 1
            case .idle:
                idleFrameCountCumulative &+= 1
            case .blank:
                blankFrameCountCumulative &+= 1
            case .suspended:
                suspendedFrameCountCumulative &+= 1
            case .started:
                startedFrameCountCumulative &+= 1
            case .stopped:
                stoppedFrameCountCumulative &+= 1
            @unknown default:
                break
            }
        }
    }

    private func recordRenderableScreenSample() {
        poolLogLock.withLock {
            renderableScreenSampleCountCumulative &+= 1
        }
    }

    private func recordCadenceAdmittedFrame() {
        poolLogLock.withLock {
            cadenceAdmittedFrameCountCumulative &+= 1
        }
    }

    private func recordDeliveredFrame() {
        poolLogLock.withLock {
            deliveredFrameCountCumulative &+= 1
        }
    }

    private func emitAudio(sampleBuffer: CMSampleBuffer) {
        guard let onAudio else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        var bufferListSizeNeeded = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, bufferListSizeNeeded > 0 else { return }

        let bufferListStorage = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            bufferListStorage.deallocate()
        }
        let bufferList = bufferListStorage.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var totalBytes = 0
        for buffer in buffers {
            totalBytes += Int(buffer.mDataByteSize)
        }
        guard totalBytes > 0 else { return }

        var pcmData = Data(capacity: totalBytes)
        for buffer in buffers {
            guard let source = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            pcmData.append(source.assumingMemoryBound(to: UInt8.self), count: Int(buffer.mDataByteSize))
        }
        guard !pcmData.isEmpty else { return }

        let asbd = asbdPointer.pointee
        let captured = CapturedAudioBuffer(
            data: pcmData,
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame),
            frameCount: max(0, CMSampleBufferGetNumSamples(sampleBuffer)),
            bytesPerFrame: Int(asbd.mBytesPerFrame),
            bitsPerChannel: Int(asbd.mBitsPerChannel),
            isFloat: (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
            isInterleaved: (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
        if MirageLogger.isEnabled(.capture) {
            audioBufferCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            if lastAudioLogTime == 0 || now - lastAudioLogTime > 2.0 {
                MirageLogger
                    .capture(
                        "Audio capture: buffers=\(audioBufferCount), rate=\(Int(captured.sampleRate))Hz, channels=\(captured.channelCount), frames=\(captured.frameCount), interleaved=\(captured.isInterleaved)"
                    )
                audioBufferCount = 0
                lastAudioLogTime = now
            }
        }
        onAudio(captured)
    }

    private func emitFrame(
        sampleBuffer: CMSampleBuffer,
        sourcePixelBuffer: CVPixelBuffer,
        frameInfo: CapturedFrameInfo,
        captureTime: CFAbsoluteTime,
        attachments: [SCStreamFrameInfo: Any]?
    ) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let cadenceTimestamp = resolvedCadenceTimestamp(
            presentationTime: presentationTime,
            attachments: attachments,
            captureTime: captureTime
        )
        if shouldDropForTargetCadence(
            cadenceTimestamp: cadenceTimestamp,
            captureTime: captureTime,
            isIdleFrame: frameInfo.isIdleFrame
        ) {
            logCadenceDrop()
            return
        }
        recordCadenceAdmittedFrame()

        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let frame = CapturedFrame(
            pixelBuffer: sourcePixelBuffer,
            presentationTime: presentationTime,
            duration: duration,
            captureTime: captureTime,
            info: frameInfo,
            backingSampleBuffer: sampleBuffer
        )
        recordDeliveredFrame()
        onFrame(frame)
    }

    nonisolated static func cadenceDecision(
        originPresentationTime: Double?,
        lastAdmittedSlotIndex: Int64,
        presentationTime: Double,
        targetFrameRate: Double,
        isIdleFrame: Bool,
        earlyToleranceFloor: Double = 0.001,
        earlyToleranceFraction: Double = 0.20
    ) -> CadenceDecision {
        guard !isIdleFrame else {
            return CadenceDecision(
                shouldDrop: false,
                originPresentationTime: originPresentationTime,
                admittedSlotIndex: lastAdmittedSlotIndex,
                expectedPresentationTime: nil
            )
        }
        guard targetFrameRate > 0 else {
            return CadenceDecision(
                shouldDrop: false,
                originPresentationTime: originPresentationTime,
                admittedSlotIndex: lastAdmittedSlotIndex,
                expectedPresentationTime: nil
            )
        }
        guard presentationTime.isFinite, presentationTime >= 0 else {
            return CadenceDecision(
                shouldDrop: false,
                originPresentationTime: originPresentationTime,
                admittedSlotIndex: lastAdmittedSlotIndex,
                expectedPresentationTime: nil
            )
        }

        let expectedInterval = 1.0 / targetFrameRate
        guard expectedInterval > 0 else {
            return CadenceDecision(
                shouldDrop: false,
                originPresentationTime: originPresentationTime,
                admittedSlotIndex: lastAdmittedSlotIndex,
                expectedPresentationTime: nil
            )
        }

        let originPresentationTime = originPresentationTime ?? presentationTime
        let tolerance = max(earlyToleranceFloor, expectedInterval * max(0.0, earlyToleranceFraction))
        let slotProgress = (presentationTime - originPresentationTime + tolerance) / expectedInterval
        let slotIndex = Int64(floor(max(0.0, slotProgress)))
        let expectedPresentationTime = originPresentationTime + (Double(slotIndex) * expectedInterval)

        if slotIndex <= lastAdmittedSlotIndex {
            return CadenceDecision(
                shouldDrop: true,
                originPresentationTime: originPresentationTime,
                admittedSlotIndex: lastAdmittedSlotIndex,
                expectedPresentationTime: expectedPresentationTime
            )
        }

        return CadenceDecision(
            shouldDrop: false,
            originPresentationTime: originPresentationTime,
            admittedSlotIndex: slotIndex,
            expectedPresentationTime: expectedPresentationTime
        )
    }

    private func logAdmissionDrop() {
        poolLogLock.withLock {
            admissionDropCount += 1
            admissionDropTotalCount &+= 1
            guard MirageLogger.isEnabled(.capture) else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if lastAdmissionLogTime == 0 || now - lastAdmissionLogTime > 2.0 {
                MirageLogger.capture("Capture admission drop: dropped \(admissionDropCount) frames")
                admissionDropCount = 0
                lastAdmissionLogTime = now
            }
        }
    }

    private func shouldDropForTargetCadence(
        cadenceTimestamp: Double,
        captureTime: CFAbsoluteTime,
        isIdleFrame: Bool
    )
    -> Bool {
        return expectationLock.withLock {
            let resolvedPresentationTime: Double = if cadenceTimestamp.isFinite, cadenceTimestamp >= 0 {
                cadenceTimestamp
            } else {
                captureTime
            }
            let originPresentationTime: Double? = cadenceOriginPresentationTime > 0
                ? cadenceOriginPresentationTime
                : nil
            let decision = Self.cadenceDecision(
                originPresentationTime: originPresentationTime,
                lastAdmittedSlotIndex: lastCadenceAdmittedSlotIndex,
                presentationTime: resolvedPresentationTime,
                targetFrameRate: targetFrameRate,
                isIdleFrame: isIdleFrame
            )

            if decision.shouldDrop {
                return true
            }

            if !isIdleFrame, targetFrameRate > 0 {
                if let expectedPresentationTime = decision.expectedPresentationTime {
                    let skewMs = abs(resolvedPresentationTime - expectedPresentationTime) * 1000.0
                    cadenceSkewTotalMs += skewMs
                    cadenceSkewSampleCount += 1
                }
                cadencePassCount += 1
                cadenceOriginPresentationTime = decision.originPresentationTime ?? 0
                lastCadenceAdmittedPresentationTime = resolvedPresentationTime
                lastCadenceAdmittedSlotIndex = decision.admittedSlotIndex
            }
            return false
        }
    }

    private func resolvedCadenceTimestamp(
        presentationTime: CMTime,
        attachments: [SCStreamFrameInfo: Any]?,
        captureTime: CFAbsoluteTime
    ) -> Double {
        if let displayTimeSeconds = resolvedDisplayTimeSeconds(from: attachments) {
            return displayTimeSeconds
        }
        let presentationSeconds = CMTimeGetSeconds(presentationTime)
        if presentationSeconds.isFinite, presentationSeconds >= 0 {
            return presentationSeconds
        }
        return captureTime
    }

    private func resolvedDisplayTimeSeconds(
        from attachments: [SCStreamFrameInfo: Any]?
    ) -> Double? {
        guard let attachments,
              let rawValue = attachments[.displayTime] else {
            return nil
        }

        let hostTime: UInt64? = if let value = rawValue as? UInt64 {
            value
        } else if let value = rawValue as? NSNumber {
            value.uint64Value
        } else if let value = rawValue as? Int {
            UInt64(max(0, value))
        } else {
            nil
        }

        guard let hostTime, hostTime > 0 else {
            return nil
        }

        let hostTimeCM = CMClockMakeHostTimeFromSystemUnits(hostTime)
        let seconds = CMTimeGetSeconds(hostTimeCM)
        guard seconds.isFinite, seconds >= 0 else {
            return nil
        }
        return seconds
    }

    private func logCadenceDrop() {
        poolLogLock.withLock {
            cadenceDropCount += 1
            cadenceDropTotalCount &+= 1
            guard MirageLogger.isEnabled(.capture) else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if lastCadenceLogTime == 0 || now - lastCadenceLogTime > 2.0 {
                let (targetFPS, cadencePasses, meanCadenceSkewMs) = expectationLock.withLock {
                    let targetFPS = Int(targetFrameRate.rounded())
                    let cadencePasses = cadencePassCount
                    let meanCadenceSkewMs = if cadenceSkewSampleCount > 0 {
                        cadenceSkewTotalMs / Double(cadenceSkewSampleCount)
                    } else {
                        0.0
                    }
                    cadencePassCount = 0
                    cadenceSkewTotalMs = 0
                    cadenceSkewSampleCount = 0
                    return (targetFPS, cadencePasses, meanCadenceSkewMs)
                }
                let meanCadenceSkewText = meanCadenceSkewMs.formatted(.number.precision(.fractionLength(2)))
                MirageLogger.capture(
                    "Capture cadence gate: cadenceDrops=\(cadenceDropCount), target=\(targetFPS)fps, cadencePasses=\(cadencePasses), meanCadenceSkewMs=\(meanCadenceSkewText)"
                )
                cadenceDropCount = 0
                lastCadenceLogTime = now
            }
        }
    }
}

#endif
