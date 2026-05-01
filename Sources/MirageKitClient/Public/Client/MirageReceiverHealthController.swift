//
//  MirageReceiverHealthController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//
//  Transport-health state machine for app-owned adaptive bitrate recovery.
//

import Foundation

public struct MirageReceiverHealthController: Sendable {
    public enum State: String, Sendable, Equatable {
        case stable
        case backingOff
    }

    public enum Action: Sendable, Equatable {
        case none
        case backoff(targetBitrateBps: Int)
        case probe(targetBitrateBps: Int)
    }

    public enum PromotionRecoveryMode: String, Sendable, Equatable {
        case settledCeiling
        case dynamicRoute
    }

    struct Diagnostics: Sendable, Equatable {
        let healthySampleCount: Int
        let stressSampleCount: Int
        let nextProbeAllowedAt: CFAbsoluteTime
        let promotionCeilingBps: Int?

        init(
            healthySampleCount: Int,
            stressSampleCount: Int,
            nextProbeAllowedAt: CFAbsoluteTime,
            promotionCeilingBps: Int?
        ) {
            self.healthySampleCount = healthySampleCount
            self.stressSampleCount = stressSampleCount
            self.nextProbeAllowedAt = nextProbeAllowedAt
            self.promotionCeilingBps = promotionCeilingBps
        }
    }

    private static let minimumBitrateBps = 2_000_000
    private static let severeBackoffStep = 0.75
    private static let normalBackoffStep = 0.85
    private static let backoffCooldownSeconds: CFAbsoluteTime = 2
    private static let recoveryHealthySampleThreshold = 2
    private static let probeHealthySampleThreshold = 3
    private static let fastStartProbeHealthySampleThreshold = 2
    private static let probeIncreaseFloorBps = 6_000_000
    private static let probeIncreasePercent = 110
    private static let probeIncreaseMaximumStepBps = 24_000_000
    private static let fastStartProbeIncreaseFloorBps = 12_000_000
    private static let fastStartProbeIncreasePercent = 120
    private static let fastStartProbeIncreaseMaximumStepBps = 32_000_000
    private static let successfulProbeCooldownSeconds: CFAbsoluteTime = 8
    private static let failedProbeCooldownSeconds: CFAbsoluteTime = 12
    private static let fastStartSuccessfulProbeCooldownSeconds: CFAbsoluteTime = 4
    private static let fastStartFailedProbeCooldownSeconds: CFAbsoluteTime = 6
    private static let fastStartDurationSeconds: CFAbsoluteTime = 12
    private static let normalBackoffPromotionCeilingStep = 0.95
    private static let severeBackoffPromotionCeilingStep = 0.85
    private static let normalBackoffPromotionCooldownSeconds: CFAbsoluteTime = 8
    private static let severeBackoffPromotionCooldownSeconds: CFAbsoluteTime = 12
    private static let promotionCeilingRecoveryHealthySampleThreshold = 8
    private static let promotionCeilingRecoveryFloorBps = 3_000_000
    private static let promotionCeilingRecoveryPercent = 105
    private static let promotionCeilingRecoveryMaximumStepBps = 12_000_000
    private static let sendQueueStressBytes = 800_000
    private static let sendQueueSevereBytes = 2_000_000
    private static let sendStartDelayStressMs = 2.0
    private static let sendStartDelaySevereMs = 6.0
    private static let sendCompletionStressMs = 12.0
    private static let sendCompletionSevereMs = 28.0
    private static let packetPacerStressMs = 0.75
    private static let packetPacerSevereMs = 2.0
    private static let transportDropSevereCount: UInt64 = 12

    public private(set) var state: State = .stable

    private var lastTransitionAt: CFAbsoluteTime?
    private var sessionStartedAt: CFAbsoluteTime?
    private var healthySampleCount: Int = 0
    private var promotionHealthySampleCount: Int = 0
    private var stressSampleCount: Int = 0
    private var nextProbeAllowedAt: CFAbsoluteTime = 0
    private var promotionCeilingBps: Int?
    private var pendingPromotion: PendingPromotion?
    public var promotionRecoveryMode: PromotionRecoveryMode

    public init(
        promotionRecoveryMode: PromotionRecoveryMode = .settledCeiling,
        promotionCeilingBps: Int? = nil
    ) {
        self.promotionRecoveryMode = promotionRecoveryMode
        self.promotionCeilingBps = promotionCeilingBps
    }

    public var learnedPromotionCeilingBps: Int? {
        promotionCeilingBps
    }

    var diagnostics: Diagnostics {
        Diagnostics(
            healthySampleCount: healthySampleCount,
            stressSampleCount: stressSampleCount,
            nextProbeAllowedAt: nextProbeAllowedAt,
            promotionCeilingBps: promotionCeilingBps
        )
    }

    public mutating func reset(
        preservingProbeCooldown: Bool = true,
        preservingSessionStart: Bool = true
    ) {
        let preservedNextProbeAllowedAt = preservingProbeCooldown ? nextProbeAllowedAt : 0
        let preservedPromotionCeilingBps = preservingProbeCooldown ? promotionCeilingBps : nil
        let preservedSessionStartedAt = preservingSessionStart ? sessionStartedAt : nil
        state = .stable
        lastTransitionAt = nil
        sessionStartedAt = preservedSessionStartedAt
        healthySampleCount = 0
        promotionHealthySampleCount = 0
        stressSampleCount = 0
        nextProbeAllowedAt = preservedNextProbeAllowedAt
        promotionCeilingBps = preservedPromotionCeilingBps
        pendingPromotion = nil
    }

    public mutating func noteProbeSucceeded(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        state = .stable
        lastTransitionAt = now
        healthySampleCount = 0
        promotionHealthySampleCount = 0
        stressSampleCount = 0
        nextProbeAllowedAt = now + probeCooldown(success: true, now: now)
        pendingPromotion = nil
    }

    public mutating func noteProbeFailed(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        state = .stable
        lastTransitionAt = now
        healthySampleCount = 0
        promotionHealthySampleCount = 0
        stressSampleCount = 0
        nextProbeAllowedAt = now + probeCooldown(success: false, now: now)
        if let pendingPromotion {
            recordFailedPromotion(
                failedBitrateBps: pendingPromotion.targetBitrateBps,
                fallbackBitrateBps: pendingPromotion.previousBitrateBps,
                severe: false,
                now: now
            )
        }
        pendingPromotion = nil
    }

    public mutating func advance(
        snapshots: [MirageClientMetricsSnapshot],
        currentBitrateBps: Int,
        ceilingBps: Int,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Action {
        guard currentBitrateBps > 0, ceilingBps > 0, !snapshots.isEmpty else {
            reset()
            return .none
        }

        let snapshot = Self.worstSnapshot(from: snapshots)
        return advance(
            snapshot: snapshot,
            currentBitrateBps: currentBitrateBps,
            ceilingBps: ceilingBps,
            now: now
        )
    }

    public mutating func advance(
        snapshot: MirageClientMetricsSnapshot?,
        currentBitrateBps: Int,
        ceilingBps: Int,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Action {
        guard currentBitrateBps > 0, ceilingBps > 0 else {
            reset()
            return .none
        }
        if sessionStartedAt == nil {
            sessionStartedAt = now
        }
        guard let snapshot else {
            reset()
            return .none
        }

        let sample = Self.sample(
            from: snapshot
        )

        if sample.isStress {
            healthySampleCount = 0
            promotionHealthySampleCount = 0
            stressSampleCount += 1
        } else {
            healthySampleCount += 1
            if sample.allowsProbePromotion {
                promotionHealthySampleCount += 1
            } else {
                promotionHealthySampleCount = 0
            }
            stressSampleCount = 0
        }

        if let promotionAction = advancePendingPromotion(
            sample: sample,
            currentBitrateBps: currentBitrateBps,
            now: now
        ) {
            return promotionAction
        }
        if pendingPromotion != nil {
            return .none
        }

        switch state {
        case .stable:
            if shouldBackOff(sample: sample, now: now) {
                return applyBackoff(
                    sample: sample,
                    currentBitrateBps: currentBitrateBps,
                    now: now
                )
            }
            if let probeTargetBitrate = probeTargetBitrate(
                sample: sample,
                currentBitrateBps: currentBitrateBps,
                ceilingBps: ceilingBps,
                now: now
            ) {
                pendingPromotion = PendingPromotion(
                    previousBitrateBps: currentBitrateBps,
                    targetBitrateBps: probeTargetBitrate,
                    cleanSampleCount: 0,
                    startedAt: now
                )
                return .probe(targetBitrateBps: probeTargetBitrate)
            }

        case .backingOff:
            if shouldBackOff(sample: sample, now: now) {
                return applyBackoff(
                    sample: sample,
                    currentBitrateBps: currentBitrateBps,
                    now: now
                )
            }

            if sample.isHealthy, healthySampleCount >= Self.recoveryHealthySampleThreshold {
                state = .stable
                lastTransitionAt = now
            }
            if state == .stable,
               let probeTargetBitrate = probeTargetBitrate(
                   sample: sample,
                   currentBitrateBps: currentBitrateBps,
                   ceilingBps: ceilingBps,
                   now: now
               ) {
                pendingPromotion = PendingPromotion(
                    previousBitrateBps: currentBitrateBps,
                    targetBitrateBps: probeTargetBitrate,
                    cleanSampleCount: 0,
                    startedAt: now
                )
                return .probe(targetBitrateBps: probeTargetBitrate)
            }
        }

        return .none
    }

    private mutating func applyBackoff(
        sample: Sample,
        currentBitrateBps: Int,
        now: CFAbsoluteTime
    ) -> Action {
        let step = sample.isSevere ? Self.severeBackoffStep : Self.normalBackoffStep
        let nextBitrate = max(Self.minimumBitrateBps, Int(Double(currentBitrateBps) * step))
        recordBackoffMemory(
            sample: sample,
            currentBitrateBps: currentBitrateBps,
            nextBitrateBps: nextBitrate,
            now: now
        )
        state = .backingOff
        lastTransitionAt = now
        healthySampleCount = 0
        promotionHealthySampleCount = 0
        stressSampleCount = 0
        guard nextBitrate < currentBitrateBps else { return .none }
        return .backoff(targetBitrateBps: nextBitrate)
    }

    private func shouldBackOff(
        sample: Sample,
        now: CFAbsoluteTime
    ) -> Bool {
        guard sample.isStress else { return false }
        if sample.isSevere {
            guard let lastTransitionAt else { return true }
            return now - lastTransitionAt >= Self.backoffCooldownSeconds
        }
        guard stressSampleCount >= Self.recoveryHealthySampleThreshold else { return false }
        guard let lastTransitionAt else { return true }
        return now - lastTransitionAt >= Self.backoffCooldownSeconds
    }

    private struct Sample: Sendable {
        let isSevere: Bool
        let isStress: Bool
        let isHealthy: Bool
        let allowsProbePromotion: Bool
    }

    private struct PendingPromotion: Sendable, Equatable {
        let previousBitrateBps: Int
        let targetBitrateBps: Int
        var cleanSampleCount: Int
        let startedAt: CFAbsoluteTime
    }

    private mutating func advancePendingPromotion(
        sample: Sample,
        currentBitrateBps: Int,
        now: CFAbsoluteTime
    ) -> Action? {
        guard var pendingPromotion else { return nil }
        guard currentBitrateBps >= pendingPromotion.targetBitrateBps else {
            self.pendingPromotion = nil
            return nil
        }

        if sample.isStress {
            recordFailedPromotion(
                failedBitrateBps: pendingPromotion.targetBitrateBps,
                fallbackBitrateBps: pendingPromotion.previousBitrateBps,
                severe: sample.isSevere,
                now: now
            )
            self.pendingPromotion = nil
            state = .backingOff
            lastTransitionAt = now
            healthySampleCount = 0
            promotionHealthySampleCount = 0
            stressSampleCount = 0
            guard pendingPromotion.previousBitrateBps < currentBitrateBps else { return nil }
            return .backoff(targetBitrateBps: pendingPromotion.previousBitrateBps)
        }

        guard sample.allowsProbePromotion else {
            self.pendingPromotion = pendingPromotion
            return nil
        }

        pendingPromotion.cleanSampleCount += 1
        if pendingPromotion.cleanSampleCount >= Self.probeHealthySampleThreshold {
            self.pendingPromotion = nil
            state = .stable
            lastTransitionAt = now
            healthySampleCount = 0
            promotionHealthySampleCount = 0
            stressSampleCount = 0
            nextProbeAllowedAt = now + probeCooldown(success: true, now: now)
        } else {
            self.pendingPromotion = pendingPromotion
        }
        return nil
    }

    private mutating func probeTargetBitrate(
        sample: Sample,
        currentBitrateBps: Int,
        ceilingBps: Int,
        now: CFAbsoluteTime
    ) -> Int? {
        guard sample.isHealthy else { return nil }
        guard sample.allowsProbePromotion else { return nil }
        let fastStartActive = isFastStartActive(now: now)
        let healthySampleThreshold = fastStartActive
            ? Self.fastStartProbeHealthySampleThreshold
            : Self.probeHealthySampleThreshold
        guard promotionHealthySampleCount >= healthySampleThreshold else { return nil }
        guard now >= nextProbeAllowedAt else { return nil }
        let effectiveCeilingBps = effectivePromotionCeiling(
            configuredCeilingBps: ceilingBps,
            currentBitrateBps: currentBitrateBps,
            now: now
        )
        guard currentBitrateBps < effectiveCeilingBps else { return nil }

        let probeIncreaseFloorBps = fastStartActive
            ? Self.fastStartProbeIncreaseFloorBps
            : Self.probeIncreaseFloorBps
        let probeIncreasePercent = fastStartActive
            ? Self.fastStartProbeIncreasePercent
            : Self.probeIncreasePercent
        let probeIncreaseMaximumStepBps = fastStartActive
            ? Self.fastStartProbeIncreaseMaximumStepBps
            : Self.probeIncreaseMaximumStepBps
        let scaledIncrease = Int(
            (Int64(currentBitrateBps) * Int64(probeIncreasePercent) + 99) / 100
        )
        let cappedStep = currentBitrateBps + probeIncreaseMaximumStepBps
        let nextBitrate = min(
            effectiveCeilingBps,
            cappedStep,
            max(currentBitrateBps + probeIncreaseFloorBps, scaledIncrease)
        )
        guard nextBitrate > currentBitrateBps else { return nil }
        return nextBitrate
    }

    private mutating func recordBackoffMemory(
        sample: Sample,
        currentBitrateBps: Int,
        nextBitrateBps: Int,
        now: CFAbsoluteTime
    ) {
        let ceilingStep = sample.isSevere
            ? Self.severeBackoffPromotionCeilingStep
            : Self.normalBackoffPromotionCeilingStep
        let cooldown = sample.isSevere
            ? Self.severeBackoffPromotionCooldownSeconds
            : Self.normalBackoffPromotionCooldownSeconds
        let rememberedCeiling = max(nextBitrateBps, Int(Double(currentBitrateBps) * ceilingStep))
        rememberPromotionCeiling(rememberedCeiling)
        nextProbeAllowedAt = max(nextProbeAllowedAt, now + cooldown)
    }

    private mutating func recordFailedPromotion(
        failedBitrateBps: Int,
        fallbackBitrateBps: Int,
        severe: Bool,
        now: CFAbsoluteTime
    ) {
        let ceilingStep = severe
            ? Self.severeBackoffPromotionCeilingStep
            : Self.normalBackoffPromotionCeilingStep
        let cooldown = severe
            ? Self.severeBackoffPromotionCooldownSeconds
            : Self.normalBackoffPromotionCooldownSeconds
        let rememberedCeiling = max(fallbackBitrateBps, Int(Double(failedBitrateBps) * ceilingStep))
        rememberPromotionCeiling(rememberedCeiling)
        nextProbeAllowedAt = max(nextProbeAllowedAt, now + cooldown)
    }

    private mutating func rememberPromotionCeiling(_ rememberedCeiling: Int) {
        if let existingPromotionCeiling = promotionCeilingBps {
            promotionCeilingBps = min(existingPromotionCeiling, rememberedCeiling)
        } else {
            promotionCeilingBps = rememberedCeiling
        }
    }

    private mutating func effectivePromotionCeiling(
        configuredCeilingBps: Int,
        currentBitrateBps: Int,
        now: CFAbsoluteTime
    ) -> Int {
        guard let promotionCeilingBps else { return configuredCeilingBps }
        guard promotionCeilingBps < configuredCeilingBps else {
            self.promotionCeilingBps = nil
            return configuredCeilingBps
        }

        let clampedCeiling = min(
            configuredCeilingBps,
            max(Self.minimumBitrateBps, promotionCeilingBps, currentBitrateBps)
        )
        self.promotionCeilingBps = clampedCeiling

        guard promotionRecoveryMode == .dynamicRoute else { return clampedCeiling }
        guard currentBitrateBps >= clampedCeiling else { return clampedCeiling }
        guard promotionHealthySampleCount >= Self.promotionCeilingRecoveryHealthySampleThreshold else {
            return clampedCeiling
        }
        guard now >= nextProbeAllowedAt else { return clampedCeiling }

        let scaledCeiling = Int(
            (Int64(clampedCeiling) * Int64(Self.promotionCeilingRecoveryPercent) + 99) / 100
        )
        let steppedCeiling = min(
            configuredCeilingBps,
            clampedCeiling + Self.promotionCeilingRecoveryMaximumStepBps,
            max(clampedCeiling + Self.promotionCeilingRecoveryFloorBps, scaledCeiling)
        )
        if steppedCeiling >= configuredCeilingBps {
            self.promotionCeilingBps = nil
            return configuredCeilingBps
        }
        self.promotionCeilingBps = steppedCeiling
        return steppedCeiling
    }

    private static func sample(
        from snapshot: MirageClientMetricsSnapshot
    ) -> Sample {
        let targetFPS = Double(max(1, snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60))
        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let transportDropCount = snapshot.hostStalePacketDrops ?? 0
        let transportAssessment = MirageTransportPressure.assess(
            sample: MirageTransportPressureSample(
                queueBytes: queueBytes,
                queueStressBytes: Self.sendQueueStressBytes,
                queueSevereBytes: Self.sendQueueSevereBytes,
                packetPacerAverageSleepMs: packetPacerAverageSleepMs,
                packetPacerStressThresholdMs: Self.packetPacerStressMs,
                packetPacerSevereThresholdMs: Self.packetPacerSevereMs,
                sendStartDelayAverageMs: sendStartDelayAverageMs,
                sendStartDelayStressThresholdMs: Self.sendStartDelayStressMs,
                sendStartDelaySevereThresholdMs: Self.sendStartDelaySevereMs,
                sendCompletionAverageMs: sendCompletionAverageMs,
                sendCompletionStressThresholdMs: Self.sendCompletionStressMs,
                sendCompletionSevereThresholdMs: Self.sendCompletionSevereMs,
                transportDropCount: transportDropCount,
                transportDropSevereCount: Self.transportDropSevereCount
            )
        )
        let pacingOnlyStress = transportAssessment.isPacerOnlyStress
        let severeDelayOnly = transportAssessment.isDelayOnlyBurst && transportAssessment.advisoryDelaySevere
        let severe = (transportAssessment.isSevere || severeDelayOnly) && !pacingOnlyStress
        let sustainedLoss = (transportAssessment.isStress || severeDelayOnly) && !pacingOnlyStress
        let healthy = !severe && !sustainedLoss
        return Sample(
            isSevere: severe,
            isStress: severe || sustainedLoss,
            isHealthy: healthy,
            allowsProbePromotion: snapshot.hasHostMetrics &&
                targetFPS > 0 &&
                snapshot.bottleneckKind != .hostCadenceLimited
        )
    }

    private func isFastStartActive(now: CFAbsoluteTime) -> Bool {
        guard let sessionStartedAt else { return false }
        return now - sessionStartedAt < Self.fastStartDurationSeconds
    }

    private func probeCooldown(success: Bool, now: CFAbsoluteTime) -> CFAbsoluteTime {
        let fastStartActive = isFastStartActive(now: now)
        return switch (success, fastStartActive) {
        case (true, true):
            Self.fastStartSuccessfulProbeCooldownSeconds
        case (true, false):
            Self.successfulProbeCooldownSeconds
        case (false, true):
            Self.fastStartFailedProbeCooldownSeconds
        case (false, false):
            Self.failedProbeCooldownSeconds
        }
    }

    private static func worstSnapshot(from snapshots: [MirageClientMetricsSnapshot]) -> MirageClientMetricsSnapshot {
        snapshots.max(by: { lhs, rhs in
            healthPriority(for: lhs) < healthPriority(for: rhs)
        }) ?? snapshots[0]
    }

    private static func healthPriority(for snapshot: MirageClientMetricsSnapshot) -> Int {
        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let transportDropCount = snapshot.hostStalePacketDrops ?? 0
        let transportAssessment = MirageTransportPressure.assess(
            sample: MirageTransportPressureSample(
                queueBytes: queueBytes,
                queueStressBytes: Self.sendQueueStressBytes,
                queueSevereBytes: Self.sendQueueSevereBytes,
                packetPacerAverageSleepMs: packetPacerAverageSleepMs,
                packetPacerStressThresholdMs: Self.packetPacerStressMs,
                packetPacerSevereThresholdMs: Self.packetPacerSevereMs,
                sendStartDelayAverageMs: sendStartDelayAverageMs,
                sendStartDelayStressThresholdMs: Self.sendStartDelayStressMs,
                sendStartDelaySevereThresholdMs: Self.sendStartDelaySevereMs,
                sendCompletionAverageMs: sendCompletionAverageMs,
                sendCompletionStressThresholdMs: Self.sendCompletionStressMs,
                sendCompletionSevereThresholdMs: Self.sendCompletionSevereMs,
                transportDropCount: transportDropCount,
                transportDropSevereCount: Self.transportDropSevereCount
            )
        )
        let pacingOnlyStress = transportAssessment.isPacerOnlyStress
        var score = 0

        if queueBytes >= Self.sendQueueSevereBytes {
            score += 800
        }
        if sendStartDelayAverageMs >= Self.sendStartDelaySevereMs ||
            sendCompletionAverageMs >= Self.sendCompletionSevereMs {
            score += 700
        }
        if !pacingOnlyStress,
           packetPacerAverageSleepMs >= Self.packetPacerSevereMs {
            score += 650
        }
        if transportDropCount >= Self.transportDropSevereCount {
            score += 600
        }
        if queueBytes >= Self.sendQueueStressBytes {
            score += 400
        }
        if sendStartDelayAverageMs >= Self.sendStartDelayStressMs ||
            sendCompletionAverageMs >= Self.sendCompletionStressMs {
            score += 300
        }
        if !pacingOnlyStress,
           packetPacerAverageSleepMs >= Self.packetPacerStressMs {
            score += 250
        }
        if transportDropCount > 0 {
            score += 200
        }

        return score
    }
}
