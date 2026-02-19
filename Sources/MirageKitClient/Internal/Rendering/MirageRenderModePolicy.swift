//
//  MirageRenderModePolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Decode-health-driven presentation and degradation policy for client rendering.
//

import Foundation
import MirageKit

enum MirageRenderModeProfile: String, Sendable, Equatable {
    case lowestLatency
    case autoTyping
    case autoSmooth
    case smoothest
}

enum MirageRenderPresentationPolicy: Sendable, Equatable {
    case latest
    case buffered(maxDepth: Int)
}

struct MirageRenderModeDecision: Sendable, Equatable {
    let profile: MirageRenderModeProfile
    let presentationPolicy: MirageRenderPresentationPolicy
    let decodeHealthy: Bool
    let allowOffCycleWake: Bool
}

enum MirageRenderModePolicy {
    static let healthyDecodeRatio = 0.95
    static let stressedDecodeRatio = 0.80
    static let maxStressBufferDepth = 3

    static func decision(
        latencyMode: MirageStreamLatencyMode,
        typingBurstActive: Bool,
        decodeHealthy: Bool,
        targetFPS: Int
    ) -> MirageRenderModeDecision {
        let normalizedTarget = normalizedTargetFPS(targetFPS)
        _ = normalizedTarget

        switch latencyMode {
        case .lowestLatency:
            return MirageRenderModeDecision(
                profile: .lowestLatency,
                presentationPolicy: .latest,
                decodeHealthy: decodeHealthy,
                allowOffCycleWake: true
            )

        case .auto:
            if typingBurstActive {
                return MirageRenderModeDecision(
                    profile: .autoTyping,
                    presentationPolicy: .latest,
                    decodeHealthy: decodeHealthy,
                    allowOffCycleWake: true
                )
            }

            return MirageRenderModeDecision(
                profile: .autoSmooth,
                presentationPolicy: .buffered(maxDepth: maxStressBufferDepth),
                decodeHealthy: decodeHealthy,
                allowOffCycleWake: false
            )

        case .smoothest:
            return MirageRenderModeDecision(
                profile: .smoothest,
                presentationPolicy: .buffered(maxDepth: maxStressBufferDepth),
                decodeHealthy: decodeHealthy,
                allowOffCycleWake: false
            )
        }
    }

    static func normalizedTargetFPS(_ fps: Int) -> Int {
        fps >= 120 ? 120 : 60
    }
}

enum MirageRenderLoopScaleDirection: String, Sendable, Equatable {
    case down
    case up
}

struct MirageRenderLoopScaleTransition: Sendable, Equatable {
    let direction: MirageRenderLoopScaleDirection
    let previousScale: Double
    let newScale: Double
}

struct MirageRenderLoopScaleController: Sendable {
    private let ladder: [Double] = [1.0, 0.9, 0.8, 0.7]
    private let downscaleThresholdCount = 3
    private let upscaleThresholdCount = 5
    private let minimumStepInterval: CFAbsoluteTime = 2.0
    private let pressureFactor = 1.2
    private let healthyFactor = 0.7

    private(set) var scaleIndex: Int = 0
    private(set) var pressureStreak: Int = 0
    private(set) var healthyStreak: Int = 0
    private(set) var lastStepTime: CFAbsoluteTime = 0

    mutating func reset() {
        scaleIndex = 0
        pressureStreak = 0
        healthyStreak = 0
        lastStepTime = 0
    }

    mutating func evaluate(
        now: CFAbsoluteTime,
        allowDegradation: Bool,
        frameBudgetMs: Double,
        drawableWaitMs: Double
    ) -> MirageRenderLoopScaleTransition? {
        let previousScale = currentScale

        guard allowDegradation else {
            reset()
            return nil
        }

        let pressure = drawableWaitMs > frameBudgetMs * pressureFactor
        let healthy = drawableWaitMs <= frameBudgetMs * healthyFactor

        if pressure {
            pressureStreak += 1
            healthyStreak = 0
        } else if healthy {
            healthyStreak += 1
            pressureStreak = 0
        } else {
            pressureStreak = 0
            healthyStreak = 0
        }

        let canStep = lastStepTime == 0 || now - lastStepTime >= minimumStepInterval

        if pressureStreak >= downscaleThresholdCount,
           canStep,
           scaleIndex < ladder.count - 1 {
            scaleIndex += 1
            pressureStreak = 0
            healthyStreak = 0
            lastStepTime = now
            return MirageRenderLoopScaleTransition(direction: .down, previousScale: previousScale, newScale: currentScale)
        }

        if healthyStreak >= upscaleThresholdCount,
           canStep,
           scaleIndex > 0 {
            scaleIndex -= 1
            pressureStreak = 0
            healthyStreak = 0
            lastStepTime = now
            return MirageRenderLoopScaleTransition(direction: .up, previousScale: previousScale, newScale: currentScale)
        }

        return nil
    }

    var currentScale: Double {
        ladder[min(max(scaleIndex, 0), ladder.count - 1)]
    }
}
