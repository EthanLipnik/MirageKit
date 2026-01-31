//
//  CaptureStreamOutput.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//

import Foundation
import CoreMedia
import CoreVideo
import os

#if os(macOS)
import ScreenCaptureKit
import AppKit

/// Stream output delegate
final class CaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onFrame: @Sendable (CapturedFrame) -> Void
    private var onAudioSample: (@Sendable (AudioSampleBuffer) -> Void)?
    private let onKeyframeRequest: @Sendable () -> Void
    private let onCaptureStall: @Sendable (String) -> Void
    private let usesDetailedMetadata: Bool
    private let tracksFrameStatus: Bool
    private var frameCount: UInt64 = 0
    private var skippedIdleFrames: UInt64 = 0

    // DIAGNOSTIC: Track all frame statuses to debug drag/menu freeze issue
    private var statusCounts: [Int: UInt64] = [:]
    private var lastStatusLogTime: CFAbsoluteTime = 0
    private var lastFrameTime: CFAbsoluteTime = 0
    private var maxFrameGap: CFAbsoluteTime = 0
    private var lastFpsLogTime: CFAbsoluteTime = 0
    private var deliveredFrameCount: UInt64 = 0
    private var deliveredCompleteCount: UInt64 = 0
    private var deliveredIdleCount: UInt64 = 0
    private var stallSignaled: Bool = false
    private var lastStallTime: CFAbsoluteTime = 0
    private var lastContentRect: CGRect = .zero

    // Frame gap watchdog: when SCK stops delivering frames (during menus/drags),
    // mark fallback mode so resume can trigger a keyframe request
    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.mirage.capture.watchdog", qos: .userInteractive)
    private var windowID: CGWindowID = 0
    private var lastDeliveredFrameTime: CFAbsoluteTime = 0
    private var frameGapThreshold: CFAbsoluteTime
    private var stallThreshold: CFAbsoluteTime
    private var expectedFrameRate: Double
    private let expectationLock = NSLock()
    private var rawFrameWindowCount: UInt64 = 0
    private var rawFrameWindowStartTime: CFAbsoluteTime = 0

    private let poolMinimumBufferCount: Int
    private let frameCopier: CaptureFrameCopier?
    private var loggedCopyFallback = false
    private var poolDropCount: UInt64 = 0
    private var lastPoolLogTime: CFAbsoluteTime = 0
    private var inFlightDropCount: UInt64 = 0
    private var lastInFlightLogTime: CFAbsoluteTime = 0
    private let poolLogLock = NSLock()

    // Track if we've been in fallback mode - when SCK resumes, we may need a keyframe
    // to prevent decode errors from reference frame discontinuity
    private var wasInFallbackMode: Bool = false
    private var fallbackStartTime: CFAbsoluteTime = 0  // When fallback mode started
    private let fallbackLock = NSLock()

    // Only request keyframe if fallback lasted longer than this threshold
    // Brief fallbacks (<200ms) don't need keyframes - they're just normal SCK latency
    private let keyframeThreshold: CFAbsoluteTime = 0.35

    init(
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onAudioSample: (@Sendable (AudioSampleBuffer) -> Void)? = nil,
        onKeyframeRequest: @escaping @Sendable () -> Void,
        onCaptureStall: @escaping @Sendable (String) -> Void = { _ in },
        windowID: CGWindowID = 0,
        usesDetailedMetadata: Bool = false,
        tracksFrameStatus: Bool = true,
        frameGapThreshold: CFAbsoluteTime = 0.100,
        stallThreshold: CFAbsoluteTime = 1.0,
        expectedFrameRate: Double = 0,
        poolMinimumBufferCount: Int = 6
    ) {
        self.onFrame = onFrame
        self.onAudioSample = onAudioSample
        self.onKeyframeRequest = onKeyframeRequest
        self.onCaptureStall = onCaptureStall
        self.windowID = windowID
        self.usesDetailedMetadata = usesDetailedMetadata
        self.tracksFrameStatus = tracksFrameStatus
        self.frameGapThreshold = frameGapThreshold
        self.stallThreshold = stallThreshold
        self.expectedFrameRate = expectedFrameRate
        self.poolMinimumBufferCount = max(2, poolMinimumBufferCount)
        self.frameCopier = CaptureFrameCopier()
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

    func updateExpectations(frameRate: Int, gapThreshold: CFAbsoluteTime, stallThreshold: CFAbsoluteTime) {
        expectationLock.withLock {
            expectedFrameRate = Double(frameRate)
            frameGapThreshold = gapThreshold
            self.stallThreshold = stallThreshold
        }
        stallSignaled = false
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

    /// Check if SCK has stopped delivering frames and trigger fallback
    private func checkForFrameGap() {
        let now = CFAbsoluteTimeGetCurrent()
        guard lastDeliveredFrameTime > 0 else { return }

        let gap = now - lastDeliveredFrameTime
        let (gapThreshold, stallLimit) = expectationLock.withLock {
            (frameGapThreshold, stallThreshold)
        }
        guard gap > gapThreshold else { return }

        // SCK has stopped delivering - mark fallback mode
        markFallbackModeForGap()

        if gap > stallLimit, !stallSignaled, now - lastStallTime > stallLimit {
            stallSignaled = true
            lastStallTime = now
            let gapMs = (gap * 1000).formatted(.number.precision(.fractionLength(1)))
            onCaptureStall("frame gap \(gapMs)ms")
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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if let onAudioSample {
                onAudioSample(AudioSampleBuffer(buffer: sampleBuffer))
            }
            return
        }

        let wallTime = CFAbsoluteTimeGetCurrent()  // Timing: when SCK delivered the frame
        let captureTime = wallTime

        // NOTE: lastDeliveredFrameTime is updated ONLY for .complete frames (below)
        // This allows the watchdog to continue firing during drags when SCK only sends .idle frames

        let diagnosticsEnabled = MirageLogger.isEnabled(.capture)

        // Check if we're resuming from fallback mode
        // Only request keyframe if fallback lasted long enough to cause decode issues
        fallbackLock.lock()
        if wasInFallbackMode {
            let fallbackDuration = CFAbsoluteTimeGetCurrent() - fallbackStartTime
            wasInFallbackMode = false

            // Only request keyframe for long fallbacks (>200ms)
            // Brief fallbacks don't cause decoder reference frame issues
            if fallbackDuration > keyframeThreshold {
                onKeyframeRequest()
                MirageLogger.capture("SCK resumed after long fallback (\(Int(fallbackDuration * 1000))ms) - scheduling keyframe")
            } else {
                MirageLogger.capture("SCK resumed after brief fallback (\(Int(fallbackDuration * 1000))ms) - no keyframe needed")
            }
        }
        fallbackLock.unlock()

        // DIAGNOSTIC: Track frame delivery gaps to detect drag/menu freeze
        if lastFrameTime > 0 {
            let gap = captureTime - lastFrameTime
            if gap > 0.1 {  // Log gaps > 100ms
                let gapMs = (gap * 1000).formatted(.number.precision(.fractionLength(1)))
                MirageLogger.capture("FRAME GAP: \(gapMs)ms since last frame")
            }
            if gap > maxFrameGap {
                maxFrameGap = gap
                if maxFrameGap > 0.2 {  // Only log significant new records
                    let gapMs = (maxFrameGap * 1000).formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.capture("NEW MAX FRAME GAP: \(gapMs)ms")
                }
            }
        }
        lastFrameTime = captureTime

        guard type == .screen else { return }

        if diagnosticsEnabled {
            rawFrameWindowCount += 1
            if rawFrameWindowStartTime == 0 {
                rawFrameWindowStartTime = captureTime
            } else if captureTime - rawFrameWindowStartTime > 2.0 {
                let elapsed = captureTime - rawFrameWindowStartTime
                let rawFps = Double(rawFrameWindowCount) / elapsed
                let rawFpsText = rawFps.formatted(.number.precision(.fractionLength(1)))
                let targetText = expectedFrameRate.formatted(.number.precision(.fractionLength(1)))
                MirageLogger.capture("Capture raw fps: \(rawFpsText) (target=\(targetText))")
                rawFrameWindowCount = 0
                rawFrameWindowStartTime = captureTime
            }
        }

        // Validate the sample buffer
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        if !tracksFrameStatus {
            lastDeliveredFrameTime = captureTime
            stallSignaled = false
            if diagnosticsEnabled {
                deliveredFrameCount += 1
                if lastFpsLogTime == 0 {
                    lastFpsLogTime = captureTime
                } else if captureTime - lastFpsLogTime > 2.0 {
                    let elapsed = captureTime - lastFpsLogTime
                    let fps = Double(deliveredFrameCount) / elapsed
                    let fpsText = fps.formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.capture("Capture fps: \(fpsText)")
                    deliveredFrameCount = 0
                    lastFpsLogTime = captureTime
                }
            }

            let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
            let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
            frameCount += 1
            if frameCount == 1 || frameCount % 600 == 0 {
                MirageLogger.capture("Frame \(frameCount): \(bufferWidth)x\(bufferHeight)")
            }

            let frameInfo = CapturedFrameInfo(
                contentRect: CGRect(x: 0, y: 0, width: CGFloat(bufferWidth), height: CGFloat(bufferHeight)),
                dirtyPercentage: 100,
                isIdleFrame: false
            )
            emitFrame(sampleBuffer: sampleBuffer, sourcePixelBuffer: pixelBuffer, frameInfo: frameInfo)
            return
        }

        // Check SCFrameStatus - track all statuses for diagnostics
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        var isIdleFrame = false
        var status: SCFrameStatus?
        if let attachments,
           let statusRawValue = attachments[.status] as? Int,
           let resolvedStatus = SCFrameStatus(rawValue: statusRawValue) {
            status = resolvedStatus

            // DIAGNOSTIC: Track status distribution
            if diagnosticsEnabled {
                statusCounts[statusRawValue, default: 0] += 1
                if captureTime - lastStatusLogTime > 2.0 {
                    lastStatusLogTime = captureTime
                    let statusNames = statusCounts.map { (key, count) in
                        let name: String
                        switch SCFrameStatus(rawValue: key) {
                        case .idle: name = "idle"
                        case .complete: name = "complete"
                        case .blank: name = "blank"
                        case .suspended: name = "suspended"
                        case .started: name = "started"
                        case .stopped: name = "stopped"
                        default: name = "unknown(\(key))"
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
            if resolvedStatus == .blank || resolvedStatus == .suspended {
                return
            }
        }

        let effectiveStatus = status ?? .complete
        guard effectiveStatus == .complete || effectiveStatus == .idle else { return }
        if effectiveStatus == .idle {
            isIdleFrame = true
        }

        // Update watchdog timer for any delivered frame so fallback only runs
        // when SCK stops delivering frames entirely.
        lastDeliveredFrameTime = captureTime
        stallSignaled = false
        if diagnosticsEnabled {
            deliveredFrameCount += 1
            if effectiveStatus == .idle {
                deliveredIdleCount += 1
            } else {
                deliveredCompleteCount += 1
            }
            if lastFpsLogTime == 0 {
                lastFpsLogTime = captureTime
            } else if captureTime - lastFpsLogTime > 2.0 {
                let elapsed = captureTime - lastFpsLogTime
                let fps = Double(deliveredFrameCount) / elapsed
                let fpsText = fps.formatted(.number.precision(.fractionLength(1)))
                MirageLogger.capture("Capture fps: \(fpsText) (complete=\(deliveredCompleteCount), idle=\(deliveredIdleCount))")
                deliveredFrameCount = 0
                deliveredCompleteCount = 0
                deliveredIdleCount = 0
                lastFpsLogTime = captureTime
            }
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
            let scaleFactor: CGFloat
            if let scale = attachments[.scaleFactor] as? CGFloat {
                scaleFactor = scale
            } else if let scale = attachments[.scaleFactor] as? Double {
                scaleFactor = CGFloat(scale)
            } else if let scale = attachments[.scaleFactor] as? NSNumber {
                scaleFactor = CGFloat(scale.doubleValue)
            } else {
                scaleFactor = 1.0
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
        let dirtyPercentage: Float
        if isIdleFrame {
            dirtyPercentage = 0
        } else if totalPixels > 0 {
            dirtyPercentage = 100
        } else {
            dirtyPercentage = 0
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
        if frameCount == 1 || frameCount % 600 == 0 {
            MirageLogger.capture("Frame \(frameCount): \(bufferWidth)x\(bufferHeight)")
        }

        // Create frame info with minimal capture metadata
        // Keyframe requests are now handled by StreamContext cadence, so don't flag here.
        let frameInfo = CapturedFrameInfo(
            contentRect: contentRect,
            dirtyPercentage: dirtyPercentage,
            isIdleFrame: isIdleFrame
        )

        emitFrame(sampleBuffer: sampleBuffer, sourcePixelBuffer: pixelBuffer, frameInfo: frameInfo)
    }

    func updateAudioHandler(_ handler: (@Sendable (AudioSampleBuffer) -> Void)?) {
        onAudioSample = handler
    }

    private func emitFrame(
        sampleBuffer: CMSampleBuffer,
        sourcePixelBuffer: CVPixelBuffer,
        frameInfo: CapturedFrameInfo
    ) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let emitFrame: @Sendable (CVPixelBuffer) -> Void = { [onFrame] pixelBuffer in
            let frame = CapturedFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                duration: duration,
                info: frameInfo
            )
            onFrame(frame)
        }

        if let frameCopier {
            let inFlightLimit = expectedFrameRate >= 120 ? 3 : 2
            let scheduleResult = frameCopier.scheduleCopy(
                pixelBuffer: sourcePixelBuffer,
                minimumBufferCount: poolMinimumBufferCount,
                inFlightLimit: inFlightLimit
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .copied(let copiedBuffer):
                    emitFrame(copiedBuffer)
                case .poolExhausted:
                    self.logPoolDrop()
                case .unsupported:
                    self.logCopyFallback("Capture copy failed: dropping frame")
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

    private func logCopyFallback(_ message: String) {
        poolLogLock.withLock {
            guard !loggedCopyFallback else { return }
            loggedCopyFallback = true
            MirageLogger.capture(message)
        }
    }
}

#endif
