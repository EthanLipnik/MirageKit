//
//  StreamContext+TypingBurst.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Auto latency-mode typing burst policy.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    struct TypingBurstSnapshot: Sendable, Equatable {
        let isActive: Bool
        let latencyBurstActive: Bool
        let deadline: CFAbsoluteTime
        let maxInFlightFrames: Int
        let qualityCeiling: Float
        let activeQuality: Float
        let captureQueueDepthOverride: Int?
        let newestFrameDrainEnabled: Bool
    }

    func noteTypingBurstActivity(
        at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        scheduleExpiry: Bool = true
    )
    async {
        guard supportsTypingBurst else { return }
        typingBurstDeadline = now + typingBurstWindow
        if !typingBurstActive {
            typingBurstActive = true
            await applyTypingBurstOverrides(now: now)
            MirageLogger.stream("Auto typing burst started for stream \(streamID)")
        }
        if scheduleExpiry { scheduleTypingBurstExpiryTask() }
    }

    func expireTypingBurstIfNeeded(
        at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        expectedDeadline: CFAbsoluteTime? = nil
    )
    async {
        guard supportsTypingBurst, typingBurstActive else { return }
        if let expectedDeadline,
           abs(expectedDeadline - typingBurstDeadline) > 0.0005 {
            return
        }
        guard now >= typingBurstDeadline else { return }
        await clearTypingBurstOverrides(now: now)
    }

    func refreshTypingBurstStateIfNeeded(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) async {
        await expireTypingBurstIfNeeded(at: now)
    }

    func typingBurstSnapshot() -> TypingBurstSnapshot {
        TypingBurstSnapshot(
            isActive: typingBurstActive,
            latencyBurstActive: latencyBurstActive,
            deadline: typingBurstDeadline,
            maxInFlightFrames: maxInFlightFrames,
            qualityCeiling: qualityCeiling,
            activeQuality: activeQuality,
            captureQueueDepthOverride: latencyBurstCaptureQueueDepthOverride,
            newestFrameDrainEnabled: latencyBurstDrainsNewestFrames
        )
    }

    func resolvedQualityCeiling() -> Float {
        min(steadyQualityCeiling, compressionQualityCeiling)
    }

    private func scheduleTypingBurstExpiryTask() {
        guard supportsTypingBurst else { return }
        typingBurstExpiryTask?.cancel()
        let expectedDeadline = typingBurstDeadline
        let waitSeconds = max(0, expectedDeadline - CFAbsoluteTimeGetCurrent())
        typingBurstExpiryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(waitSeconds))
            } catch {
                return
            }
            await self.expireTypingBurstIfNeeded(
                at: CFAbsoluteTimeGetCurrent(),
                expectedDeadline: expectedDeadline
            )
        }
    }

    private func applyTypingBurstOverrides(now: CFAbsoluteTime) async {
        await enterLatencyBurst(now: now, reason: "auto typing burst")
        await encoder?.updateAutoTypingBurstLowLatency(true)

        let forcedLimit = min(max(typingBurstInFlightLimit, 1), maxInFlightFramesCap)
        if maxInFlightFrames != forcedLimit {
            maxInFlightFrames = forcedLimit
            await encoder?.updateInFlightLimit(forcedLimit)
        }

        qualityOverBudgetCount = 0
        qualityUnderBudgetCount = 0
        lastInFlightAdjustmentTime = now
        lastQualityAdjustmentTime = 0
    }

    private func clearTypingBurstOverrides(now: CFAbsoluteTime) async {
        typingBurstActive = false
        typingBurstDeadline = 0
        typingBurstExpiryTask?.cancel()
        typingBurstExpiryTask = nil

        await encoder?.updateAutoTypingBurstLowLatency(false)
        await exitLatencyBurst(now: now, reason: "auto typing burst")

        let restoredInFlight = resolvedPostTypingBurstInFlightLimit()
        if maxInFlightFrames != restoredInFlight {
            maxInFlightFrames = restoredInFlight
            await encoder?.updateInFlightLimit(restoredInFlight)
        }

        qualityCeiling = resolvedQualityCeiling()
        if activeQuality > qualityCeiling {
            activeQuality = qualityCeiling
            await encoder?.updateQuality(activeQuality)
        }

        qualityOverBudgetCount = 0
        qualityUnderBudgetCount = 0
        lastInFlightAdjustmentTime = now
        lastQualityAdjustmentTime = 0

        MirageLogger.stream("Typing burst expired (no quality rebound) for stream \(streamID)")
    }

    func resolvedPostTypingBurstInFlightLimit() -> Int {
        return min(max(minInFlightFrames, 1), maxInFlightFramesCap)
    }

    private func enterLatencyBurst(now: CFAbsoluteTime, reason: String) async {
        let clearedBacklog = frameInbox.clear()
        if clearedBacklog > 0 {
            MirageLogger.metrics(
                "Latency burst cleared \(clearedBacklog) buffered frames for stream \(streamID)"
            )
        }

        if !latencyBurstActive {
            latencyBurstActive = true
            latencyBurstDrainsNewestFrames = true
            preLatencyBurstCaptureQueueDepthOverride = encoderConfig.captureQueueDepth
            latencyBurstCaptureQueueDepthOverride = latencyBurstCaptureQueueDepth

            do {
                try await updateLatencyBurstCaptureQueueDepthOverride(
                    latencyBurstCaptureQueueDepth,
                    reason: reason
                )
            } catch {
                MirageLogger.error(
                    .stream,
                    error: error,
                    message: "Failed to apply latency burst capture queue override: "
                )
            }
        }

        await packetSender?.resetQueue(reason: "\(reason) queue reset")
        clearBackpressureState(log: false)
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0

        if queueKeyframe(
            reason: "Latency burst recovery keyframe",
            checkInFlight: false,
            urgent: true
        ) {
            noteLossEvent(reason: "latency burst", enablePFrameFEC: true)
            markKeyframeRequestIssued()
            scheduleProcessingIfNeeded()
        }

        let queueDepthText = latencyBurstCaptureQueueDepthOverride.map(String.init) ?? "auto"
        MirageLogger.metrics(
            "Latency burst entered for stream \(streamID): reason=\(reason), queueDepth=\(queueDepthText), bufferedClears=\(clearedBacklog)"
        )
    }

    private func exitLatencyBurst(now: CFAbsoluteTime, reason: String) async {
        guard latencyBurstActive else { return }

        latencyBurstActive = false
        latencyBurstDrainsNewestFrames = false

        let restoredQueueDepth = preLatencyBurstCaptureQueueDepthOverride
        do {
            try await updateLatencyBurstCaptureQueueDepthOverride(
                restoredQueueDepth,
                reason: "\(reason) restore"
            )
        } catch {
            MirageLogger.error(
                .stream,
                error: error,
                message: "Failed to restore latency burst capture queue override: "
            )
        }

        preLatencyBurstCaptureQueueDepthOverride = nil
        latencyBurstCaptureQueueDepthOverride = nil

        let restoredQueueDepthText = restoredQueueDepth.map(String.init) ?? "auto"
        MirageLogger.metrics(
            "Latency burst exited for stream \(streamID): reason=\(reason), restoredQueueDepth=\(restoredQueueDepthText), inFlight=\(resolvedPostTypingBurstInFlightLimit())"
        )

        qualityCeiling = resolvedQualityCeiling()
        lastInFlightAdjustmentTime = now
    }

    private func updateLatencyBurstCaptureQueueDepthOverride(
        _ overrideDepth: Int?,
        reason: String
    ) async throws {
        var updatedConfig = encoderConfig
        updatedConfig.captureQueueDepth = overrideDepth
        guard updatedConfig.captureQueueDepth != encoderConfig.captureQueueDepth else { return }

        if let captureEngine {
            try await captureEngine.updateConfiguration(updatedConfig)
        }
        encoderConfig = updatedConfig

        let queueDepthText = overrideDepth.map(String.init) ?? "auto"
        MirageLogger.metrics(
            "Latency burst capture queue override updated for stream \(streamID): queueDepth=\(queueDepthText), reason=\(reason)"
        )
    }
}
#endif
