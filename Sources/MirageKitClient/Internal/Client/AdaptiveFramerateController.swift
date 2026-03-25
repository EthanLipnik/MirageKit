//
//  AdaptiveFramerateController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/25/26.
//
//  Hysteresis-based adaptive framerate controller.
//

import Foundation
import MirageKit

/// Manages adaptive framerate throttling using hysteresis bands.
///
/// Tiers: 60fps -> 30fps -> 20fps with wide hysteresis to prevent churn.
/// Drop after 10s sustained stress (<75% target), recover after 15s of
/// health (>95% target). Minimum 15s between tier changes.
@MainActor
final class AdaptiveFramerateController {
    enum Tier: Int, Comparable, CustomStringConvertible {
        case twenty = 20
        case thirty = 30
        case sixty = 60

        static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var description: String { "\(rawValue)fps" }

        var lowerTier: Tier? {
            switch self {
            case .sixty: .thirty
            case .thirty: .twenty
            case .twenty: nil
            }
        }

        var upperTier: Tier? {
            switch self {
            case .twenty: .thirty
            case .thirty: .sixty
            case .sixty: nil
            }
        }
    }

    private(set) var currentTier: Tier = .sixty
    private var lastTierChangeTime: ContinuousClock.Instant = .now
    private var stressAccumulator: Duration = .zero
    private var healthAccumulator: Duration = .zero
    private var lastEvaluationTime: ContinuousClock.Instant = .now

    /// Minimum time between tier changes to prevent oscillation.
    private static let minimumTierDuration: Duration = .seconds(15)
    /// Sustained stress required before dropping a tier.
    private static let dropStressThreshold: Duration = .seconds(10)
    /// Sustained health required before recovering a tier.
    private static let recoveryHealthThreshold: Duration = .seconds(15)
    /// Drop when decoded FPS falls below this fraction of target.
    private static let dropRatio: Double = 0.75
    /// Recover when decoded FPS exceeds this fraction of target.
    private static let recoverRatio: Double = 0.95

    /// Set to true when the user's framerate preset is 60fps or ProMotion.
    /// Adaptive throttling is disabled for explicit 20/30fps presets.
    var isEnabled: Bool = false

    /// Called every metrics evaluation cycle (~2s) with current decode
    /// performance.  Returns the target FPS if a tier change occurred,
    /// or nil if no change is needed.
    func evaluate(decodedFPS: Double, targetFPS: Int) -> Int? {
        guard isEnabled else { return nil }

        let now = ContinuousClock.now
        let elapsed = now - lastEvaluationTime
        lastEvaluationTime = now

        // Enforce minimum time between tier changes
        guard now - lastTierChangeTime >= Self.minimumTierDuration else {
            return nil
        }

        let currentTarget = Double(currentTier.rawValue)
        let isStressed = decodedFPS < currentTarget * Self.dropRatio
        let isHealthy = decodedFPS >= currentTarget * Self.recoverRatio

        if isStressed {
            stressAccumulator += elapsed
            healthAccumulator = .zero
        } else if isHealthy {
            healthAccumulator += elapsed
            stressAccumulator = .zero
        } else {
            stressAccumulator = .zero
            healthAccumulator = .zero
        }

        // Drop tier
        if stressAccumulator >= Self.dropStressThreshold, let newTier = currentTier.lowerTier {
            MirageLogger.client(
                "Adaptive framerate: dropping \(currentTier) -> \(newTier) (stress \(stressAccumulator))"
            )
            currentTier = newTier
            lastTierChangeTime = now
            stressAccumulator = .zero
            return newTier.rawValue
        }

        // Recover tier
        if healthAccumulator >= Self.recoveryHealthThreshold, let newTier = currentTier.upperTier {
            MirageLogger.client(
                "Adaptive framerate: recovering \(currentTier) -> \(newTier) (healthy \(healthAccumulator))"
            )
            currentTier = newTier
            lastTierChangeTime = now
            healthAccumulator = .zero
            return newTier.rawValue
        }

        return nil
    }

    func reset() {
        currentTier = .sixty
        stressAccumulator = .zero
        healthAccumulator = .zero
        lastTierChangeTime = .now
        lastEvaluationTime = .now
    }
}
