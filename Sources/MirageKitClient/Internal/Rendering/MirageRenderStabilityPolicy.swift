//
//  MirageRenderStabilityPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Mode-aware render recovery and smoothness promotion policy.
//

import Foundation
import MirageKit

struct MirageRenderStabilityTransition: Equatable {
    var recoveryEntered = false
    var recoveryExited = false
    var promotionChanged = false
}

struct MirageRenderStabilityStateSnapshot: Equatable {
    let recoveryActive: Bool
    let smoothestPromotionActive: Bool
    let lowFPSStreak: Int
    let healthyStreak: Int
    let holdUntil: CFAbsoluteTime
    let cooldownUntil: CFAbsoluteTime
}

struct MirageRenderStabilityPolicy {
    private(set) var recoveryActive = false
    private(set) var smoothestPromotionActive = false

    private(set) var lowFPSStreak = 0
    private(set) var healthyStreak = 0
    private(set) var holdUntil: CFAbsoluteTime = 0
    private(set) var cooldownUntil: CFAbsoluteTime = 0

    private var smoothestHealthyStreak = 0
    private let recoveryEntryFPSFactor = 0.85
    private let recoveryEntryDrawableWaitFactor = 1.30
    private let recoveryExitFPSFactor = 0.95
    private let recoveryExitDrawableWaitFactor = 0.85
    private let recoveryEntryWindows = 2
    private let recoveryExitWindows = 2
    private let recoveryHoldDuration: CFAbsoluteTime = 2.0
    private let recoveryCooldown: CFAbsoluteTime = 3.0
    private let smoothestPromotionWindows = 2

    mutating func reset() {
        recoveryActive = false
        smoothestPromotionActive = false
        lowFPSStreak = 0
        healthyStreak = 0
        holdUntil = 0
        cooldownUntil = 0
        smoothestHealthyStreak = 0
    }

    mutating func evaluate(
        now: CFAbsoluteTime,
        latencyMode: MirageStreamLatencyMode,
        targetFPS: Int,
        renderedFPS: Double,
        drawableWaitAvgMs: Double
    ) -> MirageRenderStabilityTransition {
        let normalizedTargetFPS = targetFPS >= 120 ? 120 : 60
        let frameBudgetMs = 1000.0 / Double(normalizedTargetFPS)
        let degraded = renderedFPS < Double(normalizedTargetFPS) * recoveryEntryFPSFactor ||
            drawableWaitAvgMs > frameBudgetMs * recoveryEntryDrawableWaitFactor
        let healthy = renderedFPS >= Double(normalizedTargetFPS) * recoveryExitFPSFactor &&
            drawableWaitAvgMs <= frameBudgetMs * recoveryExitDrawableWaitFactor

        var transition = MirageRenderStabilityTransition()

        if recoveryActive {
            if now >= holdUntil, healthy {
                healthyStreak += 1
            } else if now >= holdUntil {
                healthyStreak = 0
            }

            if now >= holdUntil, healthyStreak >= recoveryExitWindows {
                recoveryActive = false
                lowFPSStreak = 0
                healthyStreak = 0
                holdUntil = 0
                cooldownUntil = now + recoveryCooldown
                transition.recoveryExited = true
            }
        } else {
            healthyStreak = 0
            if now >= cooldownUntil {
                if degraded {
                    lowFPSStreak += 1
                } else {
                    lowFPSStreak = 0
                }
                if lowFPSStreak >= recoveryEntryWindows {
                    recoveryActive = true
                    lowFPSStreak = 0
                    healthyStreak = 0
                    holdUntil = now + recoveryHoldDuration
                    transition.recoveryEntered = true
                }
            } else {
                lowFPSStreak = 0
            }
        }

        let previousPromotion = smoothestPromotionActive
        if latencyMode == .smoothest, normalizedTargetFPS <= 60, !recoveryActive {
            if degraded {
                smoothestPromotionActive = false
                smoothestHealthyStreak = 0
            } else if healthy {
                smoothestHealthyStreak += 1
                if smoothestHealthyStreak >= smoothestPromotionWindows {
                    smoothestPromotionActive = true
                }
            } else {
                smoothestHealthyStreak = 0
                smoothestPromotionActive = false
            }
        } else {
            smoothestPromotionActive = false
            smoothestHealthyStreak = 0
        }
        transition.promotionChanged = previousPromotion != smoothestPromotionActive

        return transition
    }

    func snapshot() -> MirageRenderStabilityStateSnapshot {
        MirageRenderStabilityStateSnapshot(
            recoveryActive: recoveryActive,
            smoothestPromotionActive: smoothestPromotionActive,
            lowFPSStreak: lowFPSStreak,
            healthyStreak: healthyStreak,
            holdUntil: holdUntil,
            cooldownUntil: cooldownUntil
        )
    }
}
