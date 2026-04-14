//
//  VideoDecoder+Metrics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC decoder extensions.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import MirageKit

extension DecodeErrorTracker {
    func recordError() {
        lock.lock()
        defer { lock.unlock() }

        consecutiveErrors += 1
        totalErrors += 1
        recoverySuccessCount = 0
        let now = CFAbsoluteTimeGetCurrent()

        // Initial threshold fire
        if consecutiveErrors >= maxConsecutiveErrors, !thresholdFired {
            thresholdFired = true
            let timeSinceLastThreshold = lastThresholdTime > 0 ? now - lastThresholdTime : .greatestFiniteMagnitude
            guard lastThresholdTime == 0 || timeSinceLastThreshold >= thresholdDispatchCooldown else {
                let remainingMs = Int(((thresholdDispatchCooldown - timeSinceLastThreshold) * 1000).rounded(.up))
                MirageLogger.decoder(
                    "Decode error threshold reached (\(consecutiveErrors) errors) - threshold dispatch throttled \(remainingMs)ms"
                )
                return
            }

            lastThresholdTime = now
            // Call handler outside lock to avoid deadlocks
            lock.unlock()
            MirageLogger.decoder("Decode error threshold reached (\(consecutiveErrors) errors) - requesting keyframe")
            onThresholdReached()
            lock.lock()
            return
        }

        // Retry logic: if errors continue after initial request, retry periodically
        // This handles the case where the keyframe was lost over UDP
        if thresholdFired, consecutiveErrors >= retryErrorThreshold {
            let timeSinceLastRequest = now - lastThresholdTime
            if timeSinceLastRequest >= retryInterval {
                lastThresholdTime = now
                consecutiveErrors = 0 // Reset counter for next retry cycle
                recoverySuccessCount = 0
                lock.unlock()
                MirageLogger
                    .decoder("Keyframe retry - errors persisted for \(String(format: "%.1f", timeSinceLastRequest))s")
                onThresholdReached()
                lock.lock()
            }
        }
    }

    func recordSuccess() {
        lock.lock()

        let wasInRecoveryState = thresholdFired ||
            consecutiveErrors > 0 ||
            sessionRecreationAttempted ||
            recoveryTrackingArmed
        if thresholdFired || sessionRecreationAttempted || recoveryTrackingArmed {
            recoverySuccessCount += 1
            if recoverySuccessCount < recoverySuccessThreshold {
                if recoverySuccessCount == 1 || recoverySuccessCount == recoverySuccessThreshold - 1 {
                    MirageLogger
                        .decoder("Decode recovery progress \(recoverySuccessCount)/\(recoverySuccessThreshold) before clear")
                }
                lock.unlock()
                return
            }
        }

        if consecutiveErrors > 0 || sessionRecreationAttempted || wasInRecoveryState {
            MirageLogger
                .decoder(
                    "Decode recovered after \(consecutiveErrors) consecutive errors " +
                        "(sessionRecreated=\(sessionRecreationAttempted), trackingArmed=\(recoveryTrackingArmed))"
                )
        }
        consecutiveErrors = 0
        thresholdFired = false
        sessionRecreationAttempted = false
        recoveryTrackingArmed = false
        recoverySuccessCount = 0

        lock.unlock()

        // Notify recovery if we were in an error state (input was blocked)
        if wasInRecoveryState { onRecovery?() }
    }

    func requestKeyframeForDimensionChange() {
        lock.lock()
        consecutiveErrors = 0 // Reset since dimension change makes error count meaningless
        thresholdFired = true // Mark as already fired to prevent duplicate immediate requests
        lastThresholdTime = CFAbsoluteTimeGetCurrent()
        recoverySuccessCount = 0
        lock.unlock()

        MirageLogger.decoder("Requesting keyframe due to dimension change")
        onThresholdReached()
    }

    func shouldRecreateSession() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let hasErrors = thresholdFired || consecutiveErrors > 0
        if !hasErrors { return false }

        // If we haven't tried recreation yet, allow it
        if !sessionRecreationAttempted { return true }

        // If recreation was attempted, only allow again after cooldown
        let now = CFAbsoluteTimeGetCurrent()
        let timeSinceLastRecreation = now - lastSessionRecreationTime
        return timeSinceLastRecreation >= sessionRecreationCooldown
    }

    func markSessionRecreated() {
        lock.lock()
        defer { lock.unlock() }
        sessionRecreationAttempted = true
        recoveryTrackingArmed = false
        lastSessionRecreationTime = CFAbsoluteTimeGetCurrent()
        MirageLogger.decoder("Session recreation attempted - awaiting successful decode")
    }

    func beginRecoveryTracking() {
        lock.lock()
        defer { lock.unlock() }
        recoveryTrackingArmed = true
        recoverySuccessCount = 0
        MirageLogger.decoder("Decode recovery tracking armed")
    }

    func clearForDimensionChange() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveErrors = 0
        thresholdFired = false
        sessionRecreationAttempted = false
        recoveryTrackingArmed = false
        lastSessionRecreationTime = 0
        recoverySuccessCount = 0
        MirageLogger.decoder("Error tracking cleared for dimension change")
    }

    func clearForSessionReset() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveErrors = 0
        thresholdFired = false
        sessionRecreationAttempted = false
        recoveryTrackingArmed = false
        lastSessionRecreationTime = 0
        recoverySuccessCount = 0
        MirageLogger.decoder("Error tracking cleared for session reset")
    }

    func totalErrorsSnapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return totalErrors
    }
}

extension DecodePerformanceTracker {
    func record(durationMs: Double) {
        lock.lock()
        samples.append(durationMs)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        lock.unlock()
    }

    func averageMs() -> Double {
        lock.lock()
        let snapshot = samples
        lock.unlock()
        guard !snapshot.isEmpty else { return 0 }
        let total = snapshot.reduce(0, +)
        return total / Double(snapshot.count)
    }
}
