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
        let deadline: CFAbsoluteTime
        let maxInFlightFrames: Int
        let qualityCeiling: Float
        let activeQuality: Float
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
            deadline: typingBurstDeadline,
            maxInFlightFrames: maxInFlightFrames,
            qualityCeiling: qualityCeiling,
            activeQuality: activeQuality
        )
    }

    func resolvedQualityCeiling() -> Float {
        var ceiling = min(steadyQualityCeiling, compressionQualityCeiling)
        guard runtimeQualityAdjustmentEnabled else { return ceiling }
        if supportsTypingBurst, typingBurstActive { ceiling = min(ceiling, typingBurstQualityCap) }
        return ceiling
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
        let forcedLimit = min(max(typingBurstInFlightLimit, 1), maxInFlightFramesCap)
        if maxInFlightFrames != forcedLimit {
            maxInFlightFrames = forcedLimit
            await encoder?.updateInFlightLimit(forcedLimit)
        }

        if runtimeQualityAdjustmentEnabled {
            qualityCeiling = resolvedQualityCeiling()
            if activeQuality > qualityCeiling {
                activeQuality = qualityCeiling
                await encoder?.updateQuality(activeQuality)
            }
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

        let restoredInFlight = resolvedPostTypingBurstInFlightLimit()
        if maxInFlightFrames != restoredInFlight {
            maxInFlightFrames = restoredInFlight
            await encoder?.updateInFlightLimit(restoredInFlight)
        }

        if runtimeQualityAdjustmentEnabled {
            qualityCeiling = resolvedQualityCeiling()
            if activeQuality > qualityCeiling {
                activeQuality = qualityCeiling
                await encoder?.updateQuality(activeQuality)
            }
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
}
#endif
