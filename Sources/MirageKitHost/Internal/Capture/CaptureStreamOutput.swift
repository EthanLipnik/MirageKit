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
    }

    struct StallSignal: Sendable {
        let stage: StallStage
        let message: String
        let gapMs: String
        let softThresholdMs: String
        let hardThresholdMs: String
        let restartEligible: Bool
    }

    private let onFrame: @Sendable (CapturedFrame) -> Void
    private let onAudio: (@Sendable (CapturedAudioBuffer) -> Void)?
    private let onKeyframeRequest: @Sendable (KeyframeRequestReason) -> Void
    private let onCaptureStall: @Sendable (StallSignal) -> Void
    private let shouldDropFrame: (@Sendable () -> Bool)?
    private let usesDetailedMetadata: Bool
    private let tracksFrameStatus: Bool
    private let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile
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
    private var deliveredFrameCount: UInt64 = 0
    private var deliveredCompleteCount: UInt64 = 0
    private var deliveredIdleCount: UInt64 = 0
    private var callbackDurationTotalMs: Double = 0
    private var callbackDurationMaxMs: Double = 0
    private var callbackSampleCount: UInt64 = 0
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
    private let expectationLock = NSLock()
    private let deliveryStateLock = NSLock()
    private var rawFrameWindowCount: UInt64 = 0
    private var rawFrameWindowStartTime: CFAbsoluteTime = 0

    // Menu tracking/alerts can pause window capture for several seconds.
    // Use a longer stall threshold for window-based capture to avoid restart loops.
    private let windowStallThreshold: CFAbsoluteTime = 8.0
    private let displayStallThreshold: CFAbsoluteTime = 1.5

    private let poolMinimumBufferCount: Int
    private let frameCopier: CaptureFrameCopier?
    private var loggedCopyFallback = false
    private var poolDropCount: UInt64 = 0
    private var lastPoolLogTime: CFAbsoluteTime = 0
    private var inFlightDropCount: UInt64 = 0
    private var lastInFlightLogTime: CFAbsoluteTime = 0
    private var admissionDropCount: UInt64 = 0
    private var lastAdmissionLogTime: CFAbsoluteTime = 0
    private let poolLogLock = NSLock()
    private var loggedPoolWarmFailure = false

    // Track if we've been in fallback mode - when SCK resumes, we may need a keyframe
    // to prevent decode errors from reference frame discontinuity
    private var wasInFallbackMode: Bool = false
    private var fallbackStartTime: CFAbsoluteTime = 0 // When fallback mode started
    private let fallbackLock = NSLock()

    /// Only request keyframe if fallback lasted longer than this threshold
    /// Brief fallbacks (<200ms) don't need keyframes - they're just normal SCK latency
    private let keyframeThreshold: CFAbsoluteTime = 0.35

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
        targetFrameRate _: Int = 0,
        poolMinimumBufferCount: Int = 6,
        capturePressureProfile: WindowCaptureEngine.CapturePressureProfile = .baseline
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
        self.poolMinimumBufferCount = max(2, poolMinimumBufferCount)
        self.capturePressureProfile = capturePressureProfile
        frameCopier = CaptureFrameCopier()
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

    func updateExpectations(
        frameRate: Int,
        gapThreshold: CFAbsoluteTime,
        softStallThreshold: CFAbsoluteTime,
        hardRestartThreshold: CFAbsoluteTime? = nil,
        targetFrameRate _: Int
    ) {
        expectationLock.withLock {
            expectedFrameRate = Double(frameRate)
            frameGapThreshold = gapThreshold
            self.softStallThreshold = softStallThreshold
            self.hardRestartThreshold = hardRestartThreshold ?? softStallThreshold
        }
        deliveryStateLock.withLock {
            softStallSignaled = false
            hardStallSignaled = false
        }
        stopWatchdogTimer()
        startWatchdogTimer()
    }

    /// Reset fallback state (called during dimension changes)
    func clearCache() {
        fallbackLock.lock()
        wasInFallbackMode = false
        fallbackStartTime = 0
        fallbackLock.unlock()
        MirageLogger.capture("Reset fallback state for resize")
    }

    static func resolvedStallLimit(
        windowID: CGWindowID,
        configuredStallLimit: CFAbsoluteTime,
        displayStallThreshold: CFAbsoluteTime = 1.5,
        windowStallThreshold: CFAbsoluteTime = 8.0
    )
    -> CFAbsoluteTime {
        if windowID == 0 {
            // Display capture can temporarily pause under compositor pressure.
            // Keep restart responsiveness, but avoid overly eager 1.5s resets.
            let minDisplayThreshold = max(displayStallThreshold, 2.0)
            let maxDisplayThreshold: CFAbsoluteTime = 4.0
            return min(max(configuredStallLimit, minDisplayThreshold), maxDisplayThreshold)
        }
        return max(configuredStallLimit, windowStallThreshold)
    }

    func prepareBufferPool(width: Int, height: Int, pixelFormat: OSType) {
        guard let frameCopier else { return }
        let success = frameCopier.preparePool(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            minimumBufferCount: poolMinimumBufferCount
        )
        guard !success else { return }
        poolLogLock.withLock {
            guard !loggedPoolWarmFailure else { return }
            loggedPoolWarmFailure = true
            MirageLogger.capture("Capture copy pool prewarm failed")
        }
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
        if fallbackDuration > keyframeThreshold {
            onKeyframeRequest(.fallbackResume)
            MirageLogger
                .capture(
                    "event=stall_resumed durationMs=\(fallbackMs) keyframe=scheduled"
                )
        } else {
            MirageLogger
                .capture(
                    "event=stall_resumed durationMs=\(fallbackMs) keyframe=skipped"
                )
        }
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let diagnosticsEnabled = MirageLogger.isEnabled(.capture)
        let callbackStartTime = diagnosticsEnabled ? CFAbsoluteTimeGetCurrent() : 0
        defer {
            if diagnosticsEnabled {
                let durationMs = (CFAbsoluteTimeGetCurrent() - callbackStartTime) * 1000
                recordCallbackDuration(durationMs)
            }
        }

        let wallTime = CFAbsoluteTimeGetCurrent() // Timing: when SCK delivered the frame
        let captureTime = wallTime

        if type == .audio {
            emitAudio(sampleBuffer: sampleBuffer)
            return
        }

        guard type == .screen else { return }

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

        // Validate the sample buffer
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        if diagnosticsEnabled {
            updatePresentationFPS(presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }

        if !tracksFrameStatus {
            updateDeliveryState(captureTime: captureTime, isComplete: true)
            if diagnosticsEnabled {
                deliveredFrameCount += 1
                if lastFPSLogTime == 0 { lastFPSLogTime = captureTime } else if captureTime - lastFPSLogTime > 2.0 {
                    let elapsed = captureTime - lastFPSLogTime
                    let fps = Double(deliveredFrameCount) / elapsed
                    let fpsText = fps.formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.capture("Capture fps: \(fpsText)")
                    deliveredFrameCount = 0
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
            emitFrame(sampleBuffer: sampleBuffer, sourcePixelBuffer: pixelBuffer, frameInfo: frameInfo, captureTime: captureTime)
            return
        }

        // Check SCFrameStatus - track all statuses for diagnostics
        let attachments =
            (CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]])?.first
        var isIdleFrame = false
        var status: SCFrameStatus?
        if let attachments,
           let statusRawValue = attachments[.status] as? Int,
           let resolvedStatus = SCFrameStatus(rawValue: statusRawValue) {
            status = resolvedStatus

            // DIAGNOSTIC: Track status distribution
            if diagnosticsEnabled {
                statusCounts[statusRawValue, default: 0] += 1
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
        guard effectiveStatus == .complete || effectiveStatus == .idle else { return }
        if effectiveStatus == .idle { isIdleFrame = true }

        updateDeliveryState(captureTime: captureTime, isComplete: effectiveStatus == .complete)
        if diagnosticsEnabled {
            deliveredFrameCount += 1
            if effectiveStatus == .idle { deliveredIdleCount += 1 } else {
                deliveredCompleteCount += 1
            }
            if lastFPSLogTime == 0 { lastFPSLogTime = captureTime } else if captureTime - lastFPSLogTime > 2.0 {
                let elapsed = captureTime - lastFPSLogTime
                let fps = Double(deliveredFrameCount) / elapsed
                let fpsText = fps.formatted(.number.precision(.fractionLength(1)))
                MirageLogger
                    .capture("Capture fps: \(fpsText) (complete=\(deliveredCompleteCount), idle=\(deliveredIdleCount))")
                deliveredFrameCount = 0
                deliveredCompleteCount = 0
                deliveredIdleCount = 0
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
        var contentRect = CGRect(x: 0, y: 0, width: CGFloat(bufferWidth), height: CGFloat(bufferHeight))
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
                contentRect = CGRect(
                    x: rect.origin.x * scaleFactor,
                    y: rect.origin.y * scaleFactor,
                    width: rect.width * scaleFactor,
                    height: rect.height * scaleFactor
                )
                lastContentRect = contentRect
            } else if !lastContentRect.isEmpty {
                contentRect = lastContentRect
            }
        } else if !lastContentRect.isEmpty {
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
        if contentRect.isEmpty {
            contentRect = CGRect(
                x: 0,
                y: 0,
                width: CGFloat(CVPixelBufferGetWidth(pixelBuffer)),
                height: CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            )
        }

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

        emitFrame(sampleBuffer: sampleBuffer, sourcePixelBuffer: pixelBuffer, frameInfo: frameInfo, captureTime: captureTime)
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
        callbackDurationTotalMs += durationMs
        callbackDurationMaxMs = max(callbackDurationMaxMs, durationMs)
        callbackSampleCount += 1
        let now = CFAbsoluteTimeGetCurrent()
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
        captureTime: CFAbsoluteTime
    ) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let emitFrame: @Sendable (CVPixelBuffer) -> Void = { [onFrame] pixelBuffer in
            let frame = CapturedFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                duration: duration,
                captureTime: captureTime,
                info: frameInfo
            )
            onFrame(frame)
        }

        if let frameCopier {
            let inFlightLimit = Self.resolvedCopyInFlightLimit(
                expectedFrameRate: expectedFrameRate,
                poolMinimumBufferCount: poolMinimumBufferCount,
                pressureProfile: capturePressureProfile
            )
            let scheduleResult = frameCopier.scheduleCopy(
                pixelBuffer: sourcePixelBuffer,
                minimumBufferCount: poolMinimumBufferCount,
                inFlightLimit: inFlightLimit
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .copied(copiedBuffer):
                    emitFrame(copiedBuffer)
                case .poolExhausted:
                    logPoolDrop()
                case .unsupported:
                    logCopyFallback("Capture copy failed: dropping frame")
                }
            }

            switch scheduleResult {
            case .scheduled:
                return
            case .inFlightLimit:
                logInFlightDrop()
                return
            case .poolExhausted:
                logPoolDrop()
                return
            case .unsupported:
                logCopyFallback("Capture copy unsupported: dropping frame")
            }
        } else {
            logCopyFallback("Capture copy disabled: dropping frame")
        }
    }

    nonisolated static func resolvedCopyInFlightLimit(
        expectedFrameRate: Double,
        poolMinimumBufferCount: Int,
        pressureProfile: WindowCaptureEngine.CapturePressureProfile
    ) -> Int {
        // Keep SCK surface ownership bounded so a slow copy backend cannot
        // starve the capture pipeline for multiple frame intervals.
        let baselineCap = expectedFrameRate >= 120 ? 6 : 4
        let baselineDepth = max(2, poolMinimumBufferCount - 4)
        var limit = min(baselineCap, baselineDepth)
        guard pressureProfile == .tuned else { return limit }

        // Tuned profile tightens ownership in lowest-latency stress paths.
        // Gate on larger pools so lower-resolution sessions keep baseline behavior.
        let highPressureCapture = poolMinimumBufferCount >= 10
        guard highPressureCapture else { return limit }

        let tunedCap = expectedFrameRate >= 120 ? 5 : 3
        let tunedDepth = max(2, poolMinimumBufferCount - 5)
        limit = min(tunedCap, tunedDepth)
        return max(2, limit)
    }

    private func logPoolDrop() {
        poolLogLock.withLock {
            poolDropCount += 1
            guard MirageLogger.isEnabled(.capture) else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if lastPoolLogTime == 0 || now - lastPoolLogTime > 2.0 {
                MirageLogger.capture("Capture pool exhausted: dropped \(poolDropCount) frames")
                poolDropCount = 0
                lastPoolLogTime = now
            }
        }
    }

    private func logInFlightDrop() {
        poolLogLock.withLock {
            inFlightDropCount += 1
            guard MirageLogger.isEnabled(.capture) else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if lastInFlightLogTime == 0 || now - lastInFlightLogTime > 2.0 {
                MirageLogger.capture("Capture copy in-flight limit: dropped \(inFlightDropCount) frames")
                inFlightDropCount = 0
                lastInFlightLogTime = now
            }
        }
    }

    private func logAdmissionDrop() {
        poolLogLock.withLock {
            admissionDropCount += 1
            guard MirageLogger.isEnabled(.capture) else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if lastAdmissionLogTime == 0 || now - lastAdmissionLogTime > 2.0 {
                MirageLogger.capture("Capture admission drop: dropped \(admissionDropCount) frames")
                admissionDropCount = 0
                lastAdmissionLogTime = now
            }
        }
    }

    private func logCopyFallback(_ message: String) {
        poolLogLock.withLock {
            guard !loggedCopyFallback else { return }
            loggedCopyFallback = true
            MirageLogger.capture(message)
        }
    }
}

#endif
