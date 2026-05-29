//
//  CaptureStreamOutput+Watchdog.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreMedia
import Dispatch
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

// MARK: - Watchdog and Stall Recovery

extension CaptureStreamOutput {
    /// Checks capture gaps. Display capture gaps after a delivered frame are treated as dynamic idle.
    func checkForFrameGap() {
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
            displayStallThreshold: Self.displayStallThreshold,
            windowStallThreshold: Self.windowStallThreshold
        )
        let hardLimit = max(softLimit, configuredHardRestartLimit)
        let recentActivityWindow = max(2.0, min(6.0, hardLimit * 2.0))
        let anyGap = now - lastDeliveredFrameTime
        let completeGap = lastCompleteFrameTime > 0 ? now - lastCompleteFrameTime : anyGap
        let useCompleteGap = lastCompleteFrameTime > 0 && completeGap <= recentActivityWindow
        let gap = useCompleteGap ? completeGap : anyGap
        guard gap > gapThreshold else { return }

        let gapMs = (gap * 1000).formatted(.number.precision(.fractionLength(1)))
        let softMs = (softLimit * 1000).formatted(.number.precision(.fractionLength(1)))
        let hardMs = (hardLimit * 1000).formatted(.number.precision(.fractionLength(1)))
        let completeGapMs = (completeGap * 1000).formatted(.number.precision(.fractionLength(1)))
        let anyGapMs = (anyGap * 1000).formatted(.number.precision(.fractionLength(1)))
        let mode = useCompleteGap ? "content" : "any"

        if windowID == 0 {
            logDynamicSCKIdleGapIfNeeded(
                now: now,
                gapMs: gapMs,
                completeGapMs: completeGapMs,
                anyGapMs: anyGapMs,
                thresholdMs: (gapThreshold * 1000).formatted(.number.precision(.fractionLength(1))),
                mode: mode
            )
            return
        }

        markFallbackModeForGap()

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

    /// Logs dynamic ScreenCaptureKit display idleness without treating it as capture failure.
    func logDynamicSCKIdleGapIfNeeded(
        now: CFAbsoluteTime,
        gapMs: String,
        completeGapMs: String,
        anyGapMs: String,
        thresholdMs: String,
        mode: String
    ) {
        var shouldLog = false
        deliveryStateLock.withLock {
            if now - lastDynamicSCKIdleLogTime >= 2.0 {
                lastDynamicSCKIdleLogTime = now
                shouldLog = true
            }
        }
        guard shouldLog else { return }
        MirageLogger.capture(
            "event=dynamic_sck_idle gapMs=\(gapMs) completeGapMs=\(completeGapMs) " +
                "anyGapMs=\(anyGapMs) thresholdMs=\(thresholdMs) mode=\(mode)"
        )
    }

    /// Mark fallback mode when window capture stops delivering frames.
    func markFallbackModeForGap() {
        // Mark that we're in fallback mode and record start time
        fallbackLock.lock()
        do {
            defer { fallbackLock.unlock() }
            if wasInFallbackMode {
                return
            }
            fallbackStartTime = CFAbsoluteTimeGetCurrent()
            wasInFallbackMode = true
        }
    }

    func updateDeliveryState(captureTime: CFAbsoluteTime, isComplete: Bool) {
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

    func handleFallbackResumeIfNeeded() {
        // Only request keyframe if fallback lasted long enough to cause decode issues.
        let fallbackDuration: CFAbsoluteTime?
        fallbackLock.lock()
        do {
            defer { fallbackLock.unlock() }
            guard wasInFallbackMode else {
                fallbackDuration = nil
                return
            }
            fallbackDuration = CFAbsoluteTimeGetCurrent() - fallbackStartTime
            wasInFallbackMode = false
        }
        guard let fallbackDuration else { return }

        let fallbackMs = Int((fallbackDuration * 1000).rounded())
        let gapThreshold = expectationLock.withLock { frameGapThreshold }
        let thresholdMs = Int((gapThreshold * 1000).rounded())
        let fallbackMsText = "\(fallbackMs)"
        let thresholdMsText = "\(thresholdMs)"
        onCaptureStall(
            StallSignal(
                stage: .resumed,
                message: "stall resumed after \(fallbackMs)ms",
                gapMs: fallbackMsText,
                softThresholdMs: thresholdMsText,
                hardThresholdMs: thresholdMsText,
                restartEligible: false
            )
        )
        MirageLogger.capture(
            "event=stall_resumed durationMs=\(fallbackMs) keyframe=skipped_dynamic_capture thresholdMs=\(thresholdMs)"
        )
    }
}


#endif
