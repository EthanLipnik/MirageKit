//
//  MirageRenderScalePolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Auto-mode dynamic render scale recovery policy.
//

import Foundation
import MirageKit

enum MirageRenderScaleTransitionDirection: String, Equatable {
    case down
    case up
}

struct MirageRenderScaleTransition: Equatable {
    let direction: MirageRenderScaleTransitionDirection?
    let previousScale: Double
    let newScale: Double
    let degradedStreak: Int
    let healthyStreak: Int
    let secondsUntilNextStep: CFAbsoluteTime

    var changed: Bool {
        direction != nil && previousScale != newScale
    }
}

struct MirageRenderScaleSnapshot: Equatable {
    let scale: Double
    let degradedStreak: Int
    let healthyStreak: Int
    let lastStepTime: CFAbsoluteTime
}

struct MirageRenderScalePolicy {
    private let scaleLadder: [Double] = [1.0, 0.9, 0.8, 0.7]
    private let degradedWindowsForDownscale = 3
    private let healthyWindowsForUpscale = 5
    private let minStepInterval: CFAbsoluteTime = 2.0
    private let downscaleFPSFactor = 0.90
    private let downscaleDrawableWaitFactor = 1.20
    private let upscaleFPSFactor = 0.97
    private let upscaleDrawableWaitFactor = 0.70

    private(set) var scaleIndex: Int = 0
    private(set) var degradedStreak: Int = 0
    private(set) var healthyStreak: Int = 0
    private(set) var lastStepTime: CFAbsoluteTime = 0

    mutating func reset() {
        scaleIndex = 0
        degradedStreak = 0
        healthyStreak = 0
        lastStepTime = 0
    }

    mutating func evaluate(
        now: CFAbsoluteTime,
        latencyMode: MirageStreamLatencyMode,
        targetFPS: Int,
        renderedFPS: Double,
        drawableWaitAvgMs: Double,
        typingBurstActive: Bool
    ) -> MirageRenderScaleTransition {
        let normalizedTargetFPS = targetFPS >= 120 ? 120 : 60
        let previousScale = currentScale
        let frameBudgetMs = 1000.0 / Double(normalizedTargetFPS)
        let lowFPS = renderedFPS < (Double(normalizedTargetFPS) * downscaleFPSFactor)
        let highDrawableWait = drawableWaitAvgMs > (frameBudgetMs * downscaleDrawableWaitFactor)
        let stableFPS = renderedFPS >= (Double(normalizedTargetFPS) * upscaleFPSFactor)
        let lowDrawableWait = drawableWaitAvgMs <= (frameBudgetMs * upscaleDrawableWaitFactor)
        let degraded: Bool
        let healthy: Bool
        if latencyMode == .lowestLatency {
            // Lowest-latency mode treats drawable wait as the primary scaling signal.
            // Low rendered FPS alone can be scheduler-phase bound and downscaling in that
            // state reduces quality without improving cadence.
            degraded = highDrawableWait
            healthy = lowDrawableWait
        } else {
            degraded = lowFPS || highDrawableWait
            healthy = stableFPS && lowDrawableWait
        }

        if (latencyMode != .auto && latencyMode != .lowestLatency) || normalizedTargetFPS > 60 {
            degradedStreak = 0
            healthyStreak = 0
            if scaleIndex != 0 {
                scaleIndex = 0
                lastStepTime = now
                return MirageRenderScaleTransition(
                    direction: .up,
                    previousScale: previousScale,
                    newScale: currentScale,
                    degradedStreak: degradedStreak,
                    healthyStreak: healthyStreak,
                    secondsUntilNextStep: minStepInterval
                )
            }
            return MirageRenderScaleTransition(
                direction: nil,
                previousScale: previousScale,
                newScale: previousScale,
                degradedStreak: degradedStreak,
                healthyStreak: healthyStreak,
                secondsUntilNextStep: remainingStepInterval(now: now)
            )
        }

        if degraded {
            degradedStreak += 1
            healthyStreak = 0
        } else if healthy {
            healthyStreak += 1
            if !typingBurstActive {
                degradedStreak = 0
            }
        } else {
            degradedStreak = 0
            healthyStreak = 0
        }

        let stepIntervalElapsed = lastStepTime == 0 || now - lastStepTime >= minStepInterval

        if degradedStreak >= degradedWindowsForDownscale,
           stepIntervalElapsed,
           scaleIndex < (scaleLadder.count - 1) {
            scaleIndex += 1
            degradedStreak = 0
            healthyStreak = 0
            lastStepTime = now
            return MirageRenderScaleTransition(
                direction: .down,
                previousScale: previousScale,
                newScale: currentScale,
                degradedStreak: degradedStreak,
                healthyStreak: healthyStreak,
                secondsUntilNextStep: minStepInterval
            )
        }

        if !typingBurstActive,
           healthyStreak >= healthyWindowsForUpscale,
           stepIntervalElapsed,
           scaleIndex > 0 {
            scaleIndex -= 1
            degradedStreak = 0
            healthyStreak = 0
            lastStepTime = now
            return MirageRenderScaleTransition(
                direction: .up,
                previousScale: previousScale,
                newScale: currentScale,
                degradedStreak: degradedStreak,
                healthyStreak: healthyStreak,
                secondsUntilNextStep: minStepInterval
            )
        }

        return MirageRenderScaleTransition(
            direction: nil,
            previousScale: previousScale,
            newScale: previousScale,
            degradedStreak: degradedStreak,
            healthyStreak: healthyStreak,
            secondsUntilNextStep: remainingStepInterval(now: now)
        )
    }

    var currentScale: Double {
        scaleLadder[min(max(scaleIndex, 0), scaleLadder.count - 1)]
    }

    func snapshot() -> MirageRenderScaleSnapshot {
        MirageRenderScaleSnapshot(
            scale: currentScale,
            degradedStreak: degradedStreak,
            healthyStreak: healthyStreak,
            lastStepTime: lastStepTime
        )
    }

    private func remainingStepInterval(now: CFAbsoluteTime) -> CFAbsoluteTime {
        guard lastStepTime > 0 else { return 0 }
        return max(0, minStepInterval - (now - lastStepTime))
    }
}
