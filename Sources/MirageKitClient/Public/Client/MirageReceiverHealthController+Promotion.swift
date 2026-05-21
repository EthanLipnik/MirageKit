//
//  MirageReceiverHealthController+Promotion.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation

extension MirageReceiverHealthController {
    /// Records that the most recent promotion probe succeeded.
    public mutating func noteProbeSucceeded(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        state = .stable
        lastTransitionAt = now
        resetSampleCounters()
        nextProbeAllowedAt = now + probeCooldown(success: true, now: now)
        pendingPromotion = nil
    }

    /// Records that the most recent promotion probe failed.
    public mutating func noteProbeFailed(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        state = .stable
        lastTransitionAt = now
        resetSampleCounters()
        nextProbeAllowedAt = now + probeCooldown(success: false, now: now)
        if let pendingPromotion {
            recordFailedPromotion(
                failedBitrateBps: pendingPromotion.targetBitrateBps,
                fallbackBitrateBps: pendingPromotion.previousBitrateBps,
                severe: false
            )
        }
        pendingPromotion = nil
    }

    /// Starts a promotion probe when the clean-sample streak and cooldown allow it.
    mutating func probeActionIfReady(
        sample: ReceiverHealthSample,
        currentBitrateBps: Int,
        ceilingBps: Int,
        now: CFAbsoluteTime,
        allowsNewProbe: Bool
    ) -> Action {
        guard allowsNewProbe,
              let probeTarget = probeTargetBitrate(
                  sample: sample,
                  currentBitrateBps: currentBitrateBps,
                  ceilingBps: ceilingBps,
                  now: now
              ) else {
            return .none
        }
        pendingPromotion = ReceiverPendingPromotion(
            previousBitrateBps: currentBitrateBps,
            targetBitrateBps: probeTarget,
            cleanSampleCount: 0,
            startedAt: now
        )
        return .probe(targetBitrateBps: probeTarget)
    }

    /// Advances or resolves an in-flight promotion probe.
    mutating func advancePendingPromotion(
        sample: ReceiverHealthSample,
        currentBitrateBps: Int,
        now: CFAbsoluteTime,
        allowsBackoff: Bool
    ) -> Action? {
        guard var pendingPromotion else { return nil }
        guard currentBitrateBps >= pendingPromotion.targetBitrateBps else {
            self.pendingPromotion = nil
            return nil
        }

        if sample.hasTransportPressure {
            guard allowsBackoff else {
                self.pendingPromotion = nil
                state = .stable
                return nil
            }
            recordFailedPromotion(
                failedBitrateBps: pendingPromotion.targetBitrateBps,
                fallbackBitrateBps: pendingPromotion.previousBitrateBps,
                severe: sample.hasSevereTransportPressure
            )
            self.pendingPromotion = nil
            state = .backingOff
            lastTransitionAt = now
            resetSampleCounters()
            nextProbeAllowedAt = max(nextProbeAllowedAt, now + probeCooldown(success: false, now: now))
            guard pendingPromotion.previousBitrateBps < currentBitrateBps else { return nil }
            return .backoff(targetBitrateBps: pendingPromotion.previousBitrateBps)
        }

        guard sample.allowsProbePromotion else {
            if now - pendingPromotion.startedAt >= Self.pendingProbeTimeoutSeconds {
                self.pendingPromotion = nil
                nextProbeAllowedAt = max(nextProbeAllowedAt, now + Self.failedProbeCooldownSeconds)
            } else {
                self.pendingPromotion = pendingPromotion
            }
            return nil
        }

        pendingPromotion.cleanSampleCount += 1
        if pendingPromotion.cleanSampleCount >= Self.pendingProbeHealthySampleThreshold {
            self.pendingPromotion = nil
            state = .stable
            lastTransitionAt = now
            resetSampleCounters()
            nextProbeAllowedAt = now + probeCooldown(success: true, now: now)
            clearPromotionCeilingIfReached(currentBitrateBps)
        } else {
            self.pendingPromotion = pendingPromotion
        }
        return nil
    }

    /// Computes the next promotion target, respecting learned ceilings and fast-start policy.
    mutating func probeTargetBitrate(
        sample: ReceiverHealthSample,
        currentBitrateBps: Int,
        ceilingBps: Int,
        now: CFAbsoluteTime
    ) -> Int? {
        guard sample.isTransportClean else { return nil }
        guard sample.allowsProbePromotion else { return nil }
        let fastStartActive = isFastStartActive(now: now)
        let conservativeProximity = promotionRecoveryMode == .conservativeProximity
        let healthySampleThreshold = if conservativeProximity {
            Self.conservativeProbeHealthySampleThreshold
        } else if fastStartActive {
            Self.fastStartProbeHealthySampleThreshold
        } else {
            Self.probeHealthySampleThreshold
        }
        guard promotionHealthySampleCount >= healthySampleThreshold else { return nil }
        guard now >= nextProbeAllowedAt else { return nil }
        let effectiveCeilingBps = effectivePromotionCeiling(
            configuredCeilingBps: ceilingBps,
            currentBitrateBps: currentBitrateBps,
            now: now
        )
        guard currentBitrateBps < effectiveCeilingBps else { return nil }

        let increaseFloorBps = if conservativeProximity {
            Self.conservativeProbeIncreaseFloorBps
        } else if fastStartActive {
            Self.fastStartProbeIncreaseFloorBps
        } else {
            Self.normalProbeIncreaseFloorBps
        }
        let increasePercent = if conservativeProximity {
            Self.conservativeProbeIncreasePercent
        } else if fastStartActive {
            Self.fastStartProbeIncreasePercent
        } else {
            Self.normalProbeIncreasePercent
        }
        let increaseMaximumStepBps = if conservativeProximity {
            Self.conservativeProbeIncreaseMaximumStepBps
        } else if fastStartActive {
            Self.fastStartProbeIncreaseMaximumStepBps
        } else {
            Self.normalProbeIncreaseMaximumStepBps
        }
        let scaledIncrease = Int(
            (Int64(currentBitrateBps) * Int64(increasePercent) + 99) / 100
        )
        let cappedStep = currentBitrateBps + increaseMaximumStepBps
        let nextBitrate = min(
            effectiveCeilingBps,
            cappedStep,
            max(currentBitrateBps + increaseFloorBps, scaledIncrease)
        )
        guard nextBitrate > currentBitrateBps else { return nil }
        return nextBitrate
    }

    /// Learns a promotion ceiling from a failed probe.
    mutating func recordFailedPromotion(
        failedBitrateBps: Int,
        fallbackBitrateBps: Int,
        severe: Bool
    ) {
        let ceilingStep = severe
            ? Self.severeBackoffPromotionCeilingStep
            : Self.normalBackoffPromotionCeilingStep
        let rememberedCeiling = max(fallbackBitrateBps, Int(Double(failedBitrateBps) * ceilingStep))
        rememberPromotionCeiling(rememberedCeiling)
    }

    /// Stores the most conservative learned promotion ceiling.
    mutating func rememberPromotionCeiling(_ rememberedCeiling: Int) {
        guard rememberedCeiling > 0 else { return }
        if let existingPromotionCeiling = promotionCeilingBps {
            promotionCeilingBps = min(existingPromotionCeiling, rememberedCeiling)
        } else {
            promotionCeilingBps = rememberedCeiling
        }
    }

    /// Removes the learned ceiling once the current bitrate reaches it cleanly.
    mutating func clearPromotionCeilingIfReached(_ currentBitrateBps: Int) {
        guard let promotionCeilingBps else { return }
        if currentBitrateBps >= promotionCeilingBps {
            self.promotionCeilingBps = nil
        }
    }

    /// Returns the effective promotion ceiling after learned-ceiling recovery.
    mutating func effectivePromotionCeiling(
        configuredCeilingBps: Int,
        currentBitrateBps: Int,
        now: CFAbsoluteTime
    ) -> Int {
        guard let promotionCeilingBps else { return configuredCeilingBps }
        guard promotionCeilingBps < configuredCeilingBps else {
            self.promotionCeilingBps = nil
            return configuredCeilingBps
        }

        var clampedCeiling = min(
            configuredCeilingBps,
            max(Self.minimumBitrateBps, promotionCeilingBps, currentBitrateBps)
        )
        let requiredHealthySamples = switch promotionRecoveryMode {
        case .dynamicRoute:
            Self.dynamicRouteCeilingRecoveryHealthySamples
        case .conservativeProximity:
            Self.ceilingRecoveryHealthySamples + 4
        case .settledCeiling:
            Self.ceilingRecoveryHealthySamples
        }
        if currentBitrateBps >= clampedCeiling,
           promotionHealthySampleCount >= requiredHealthySamples,
           now >= nextProbeAllowedAt {
            let scaledCeiling = Int(
                (Int64(clampedCeiling) * Int64(Self.promotionCeilingRecoveryPercent) + 99) / 100
            )
            clampedCeiling = min(
                configuredCeilingBps,
                clampedCeiling + Self.promotionCeilingRecoveryMaximumStepBps,
                max(clampedCeiling + Self.promotionCeilingRecoveryFloorBps, scaledCeiling)
            )
        }

        if clampedCeiling >= configuredCeilingBps {
            self.promotionCeilingBps = nil
            return configuredCeilingBps
        }
        self.promotionCeilingBps = clampedCeiling
        return clampedCeiling
    }
}
