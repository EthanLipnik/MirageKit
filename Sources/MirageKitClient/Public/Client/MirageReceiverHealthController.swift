//
//  MirageReceiverHealthController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
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

    private struct Sample: Sendable {
        let hasSevereTransportPressure: Bool
        let hasTransportPressure: Bool
        let isTransportClean: Bool
        let allowsProbePromotion: Bool
        let suppressesProbePromotion: Bool
        let transportPressureReason: String?
    }

    private struct PendingPromotion: Sendable, Equatable {
        let previousBitrateBps: Int
        let targetBitrateBps: Int
        var cleanSampleCount: Int
        let startedAt: CFAbsoluteTime
    }

    private static let minimumBitrateBps = 12_000_000
    private static let severeBackoffStep = 0.85
    private static let normalBackoffStep = 0.90
    private static let backoffCooldownSeconds: CFAbsoluteTime = 8
    private static let recoveryHealthySampleThreshold = 3
    private static let severeStressSampleThreshold = 2
    private static let normalStressSampleThreshold = 3
    private static let probeHealthySampleThreshold = 4
    private static let fastStartProbeHealthySampleThreshold = 2
    private static let pendingProbeHealthySampleThreshold = 2
    private static let pendingProbeTimeoutSeconds: CFAbsoluteTime = 12
    private static let normalProbeIncreaseFloorBps = 6_000_000
    private static let normalProbeIncreasePercent = 115
    private static let normalProbeIncreaseMaximumStepBps = 24_000_000
    private static let fastStartProbeIncreaseFloorBps = 12_000_000
    private static let fastStartProbeIncreasePercent = 120
    private static let fastStartProbeIncreaseMaximumStepBps = 32_000_000
    private static let successfulProbeCooldownSeconds: CFAbsoluteTime = 8
    private static let failedProbeCooldownSeconds: CFAbsoluteTime = 12
    private static let probeSuppressionCooldownSeconds: CFAbsoluteTime = 3
    private static let fastStartSuccessfulProbeCooldownSeconds: CFAbsoluteTime = 4
    private static let fastStartFailedProbeCooldownSeconds: CFAbsoluteTime = 8
    private static let fastStartDurationSeconds: CFAbsoluteTime = 12
    private static let normalBackoffPromotionCeilingStep = 0.95
    private static let severeBackoffPromotionCeilingStep = 0.90
    private static let promotionCeilingRecoveryHealthySampleThreshold = 12
    private static let dynamicRoutePromotionCeilingRecoveryHealthySampleThreshold = 8
    private static let promotionCeilingRecoveryFloorBps = 3_000_000
    private static let promotionCeilingRecoveryPercent = 105
    private static let promotionCeilingRecoveryMaximumStepBps = 12_000_000
    private static let sendQueueStressBytes = 800_000
    private static let sendQueueSevereBytes = 2_000_000
    private static let sendStartDelayStressMs = 4.0
    private static let sendStartDelaySevereMs = 8.0
    private static let sendCompletionStressMs = 18.0
    private static let sendCompletionSevereMs = 32.0
    private static let packetPacerStressMs = 0.75
    private static let packetPacerSevereMs = 2.0
    private static let transportDropStressCount: UInt64 = 4
    private static let transportDropSevereCount: UInt64 = 24
    private static let deliveryStressRatio = 0.90
    private static let deliverySevereRatio = 0.70
    private static let clientStarvationStressRatio = 0.50

    public private(set) var state: State = .stable
    public var promotionRecoveryMode: PromotionRecoveryMode
    public private(set) var lastTransportPressureReason: String?

    private var lastTransitionAt: CFAbsoluteTime?
    private var sessionStartedAt: CFAbsoluteTime?
    private var healthySampleCount: Int = 0
    private var promotionHealthySampleCount: Int = 0
    private var stressSampleCount: Int = 0
    private var nextProbeAllowedAt: CFAbsoluteTime = 0
    private var promotionCeilingBps: Int?
    private var pendingPromotion: PendingPromotion?

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
        lastTransportPressureReason = nil
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
                severe: false
            )
        }
        pendingPromotion = nil
    }

    public mutating func advance(
        snapshots: [MirageClientMetricsSnapshot],
        currentBitrateBps: Int,
        ceilingBps: Int,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        allowsNewProbe: Bool = true,
        allowsBackoff: Bool = true,
        minimumHealthyFrameRate: Int? = nil
    ) -> Action {
        guard currentBitrateBps > 0, ceilingBps > 0, !snapshots.isEmpty else {
            reset()
            return .none
        }
        return advance(
            snapshot: Self.worstSnapshot(
                from: snapshots,
                minimumHealthyFrameRate: minimumHealthyFrameRate
            ),
            currentBitrateBps: currentBitrateBps,
            ceilingBps: ceilingBps,
            now: now,
            allowsNewProbe: allowsNewProbe,
            allowsBackoff: allowsBackoff,
            minimumHealthyFrameRate: minimumHealthyFrameRate
        )
    }

    public mutating func advance(
        snapshot: MirageClientMetricsSnapshot?,
        currentBitrateBps: Int,
        ceilingBps: Int,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        allowsNewProbe: Bool = true,
        allowsBackoff: Bool = true,
        minimumHealthyFrameRate: Int? = nil
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
            from: snapshot,
            minimumHealthyFrameRate: minimumHealthyFrameRate
        )
        lastTransportPressureReason = sample.transportPressureReason
        updateSampleCounters(sample: sample, now: now, allowsBackoff: allowsBackoff)

        if let promotionAction = advancePendingPromotion(
            sample: sample,
            currentBitrateBps: currentBitrateBps,
            now: now,
            allowsBackoff: allowsBackoff
        ) {
            return promotionAction
        }
        if pendingPromotion != nil {
            return .none
        }

        switch state {
        case .stable:
            if allowsBackoff, shouldBackOff(sample: sample, now: now) {
                return applyBackoff(
                    sample: sample,
                    currentBitrateBps: currentBitrateBps,
                    now: now
                )
            }
            return probeActionIfReady(
                sample: sample,
                currentBitrateBps: currentBitrateBps,
                ceilingBps: ceilingBps,
                now: now,
                allowsNewProbe: allowsNewProbe
            )

        case .backingOff:
            if allowsBackoff, shouldBackOff(sample: sample, now: now) {
                return applyBackoff(
                    sample: sample,
                    currentBitrateBps: currentBitrateBps,
                    now: now
                )
            }

            if sample.isTransportClean, healthySampleCount >= Self.recoveryHealthySampleThreshold {
                state = .stable
                lastTransitionAt = now
            }
            if state == .stable {
                return probeActionIfReady(
                    sample: sample,
                    currentBitrateBps: currentBitrateBps,
                    ceilingBps: ceilingBps,
                    now: now,
                    allowsNewProbe: allowsNewProbe
                )
            }
        }

        return .none
    }

    private mutating func updateSampleCounters(
        sample: Sample,
        now: CFAbsoluteTime,
        allowsBackoff: Bool
    ) {
        if sample.suppressesProbePromotion {
            nextProbeAllowedAt = max(nextProbeAllowedAt, now + Self.probeSuppressionCooldownSeconds)
        }

        if sample.hasTransportPressure && allowsBackoff {
            healthySampleCount = 0
            promotionHealthySampleCount = 0
            stressSampleCount += 1
        } else if sample.hasTransportPressure {
            healthySampleCount = 0
            promotionHealthySampleCount = 0
            stressSampleCount = 0
            pendingPromotion = nil
        } else {
            healthySampleCount += 1
            if sample.allowsProbePromotion {
                promotionHealthySampleCount += 1
            } else {
                promotionHealthySampleCount = 0
            }
            stressSampleCount = 0
        }
    }

    private mutating func probeActionIfReady(
        sample: Sample,
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
        pendingPromotion = PendingPromotion(
            previousBitrateBps: currentBitrateBps,
            targetBitrateBps: probeTarget,
            cleanSampleCount: 0,
            startedAt: now
        )
        return .probe(targetBitrateBps: probeTarget)
    }

    private mutating func applyBackoff(
        sample: Sample,
        currentBitrateBps: Int,
        now: CFAbsoluteTime
    ) -> Action {
        let step = sample.hasSevereTransportPressure ? Self.severeBackoffStep : Self.normalBackoffStep
        let nextBitrate = max(Self.minimumBitrateBps, Int(Double(currentBitrateBps) * step))
        rememberPromotionCeiling(
            max(
                nextBitrate,
                Int(Double(currentBitrateBps) * (
                    sample.hasSevereTransportPressure
                        ? Self.severeBackoffPromotionCeilingStep
                        : Self.normalBackoffPromotionCeilingStep
                ))
            )
        )
        state = .backingOff
        lastTransitionAt = now
        healthySampleCount = 0
        promotionHealthySampleCount = 0
        stressSampleCount = 0
        nextProbeAllowedAt = max(nextProbeAllowedAt, now + Self.backoffCooldownSeconds)
        guard nextBitrate < currentBitrateBps else { return .none }
        return .backoff(targetBitrateBps: nextBitrate)
    }

    private func shouldBackOff(
        sample: Sample,
        now: CFAbsoluteTime
    ) -> Bool {
        guard sample.hasTransportPressure else { return false }
        let requiredSampleCount = sample.hasSevereTransportPressure
            ? Self.severeStressSampleThreshold
            : Self.normalStressSampleThreshold
        guard stressSampleCount >= requiredSampleCount else { return false }
        guard let lastTransitionAt else { return true }
        return now - lastTransitionAt >= Self.backoffCooldownSeconds
    }

    private mutating func advancePendingPromotion(
        sample: Sample,
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
            healthySampleCount = 0
            promotionHealthySampleCount = 0
            stressSampleCount = 0
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
            healthySampleCount = 0
            promotionHealthySampleCount = 0
            stressSampleCount = 0
            nextProbeAllowedAt = now + probeCooldown(success: true, now: now)
            clearPromotionCeilingIfReached(currentBitrateBps)
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
        guard sample.isTransportClean else { return nil }
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

        let increaseFloorBps = fastStartActive
            ? Self.fastStartProbeIncreaseFloorBps
            : Self.normalProbeIncreaseFloorBps
        let increasePercent = fastStartActive
            ? Self.fastStartProbeIncreasePercent
            : Self.normalProbeIncreasePercent
        let increaseMaximumStepBps = fastStartActive
            ? Self.fastStartProbeIncreaseMaximumStepBps
            : Self.normalProbeIncreaseMaximumStepBps
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

    private mutating func recordFailedPromotion(
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

    private mutating func rememberPromotionCeiling(_ rememberedCeiling: Int) {
        guard rememberedCeiling > 0 else { return }
        if let existingPromotionCeiling = promotionCeilingBps {
            promotionCeilingBps = min(existingPromotionCeiling, rememberedCeiling)
        } else {
            promotionCeilingBps = rememberedCeiling
        }
    }

    private mutating func clearPromotionCeilingIfReached(_ currentBitrateBps: Int) {
        guard let promotionCeilingBps else { return }
        if currentBitrateBps >= promotionCeilingBps {
            self.promotionCeilingBps = nil
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

        var clampedCeiling = min(
            configuredCeilingBps,
            max(Self.minimumBitrateBps, promotionCeilingBps, currentBitrateBps)
        )
        let requiredHealthySamples = promotionRecoveryMode == .dynamicRoute
            ? Self.dynamicRoutePromotionCeilingRecoveryHealthySampleThreshold
            : Self.promotionCeilingRecoveryHealthySampleThreshold
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

    private static func sample(
        from snapshot: MirageClientMetricsSnapshot,
        minimumHealthyFrameRate: Int? = nil
    ) -> Sample {
        guard snapshot.hasHostMetrics else {
            return Sample(
                hasSevereTransportPressure: false,
                hasTransportPressure: false,
                isTransportClean: false,
                allowsProbePromotion: false,
                suppressesProbePromotion: true,
                transportPressureReason: nil
            )
        }

        let requestedTargetFrameRate = max(1, snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60)
        let targetFPS = Double(
            Self.effectiveHealthFrameRate(
                requestedTargetFrameRate: requestedTargetFrameRate,
                minimumHealthyFrameRate: minimumHealthyFrameRate
            )
        )
        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let transportDropCount = (snapshot.hostStalePacketDrops ?? 0) +
            (snapshot.hostSenderLocalDeadlineDrops ?? 0)

        let queueStress = queueBytes >= Self.sendQueueStressBytes
        let queueSevere = queueBytes >= Self.sendQueueSevereBytes
        let sendDelayStress = sendStartDelayAverageMs >= Self.sendStartDelayStressMs ||
            sendCompletionAverageMs >= Self.sendCompletionStressMs
        let sendDelaySevere = sendStartDelayAverageMs >= Self.sendStartDelaySevereMs ||
            sendCompletionAverageMs >= Self.sendCompletionSevereMs
        let pacerStress = packetPacerAverageSleepMs >= Self.packetPacerStressMs
        let pacerSevere = packetPacerAverageSleepMs >= Self.packetPacerSevereMs
        let dropStress = transportDropCount >= Self.transportDropStressCount
        let dropSevere = transportDropCount >= Self.transportDropSevereCount

        let hostPipelineHealthy = Self.hostPipelineHealthy(snapshot: snapshot, targetFPS: targetFPS)
        let clientCanVerifyTransport = Self.clientCanVerifyTransport(snapshot: snapshot, targetFPS: targetFPS)
        let deliveryRatio = snapshot.hostEncodedFPS > 0
            ? max(0, snapshot.receivedFPS) / max(1, snapshot.hostEncodedFPS)
            : 1
        let deliveryBelowHealthFloor = max(0, snapshot.receivedFPS) < targetFPS * Self.deliveryStressRatio
        let deliverySevereBelowHealthFloor = max(0, snapshot.receivedFPS) < targetFPS * Self.deliverySevereRatio
        let deliveryStress = hostPipelineHealthy &&
            clientCanVerifyTransport &&
            deliveryBelowHealthFloor &&
            deliveryRatio < Self.deliveryStressRatio
        let deliverySevere = hostPipelineHealthy &&
            clientCanVerifyTransport &&
            deliverySevereBelowHealthFloor &&
            deliveryRatio < Self.deliverySevereRatio
        let clientKeyframeStarved = hostPipelineHealthy &&
            snapshot.clientReassemblerPendingKeyframeCount > 0
        let clientStarvationStress = clientKeyframeStarved && (
            snapshot.receivedFPS < targetFPS * Self.clientStarvationStressRatio ||
                snapshot.decodedFPS < targetFPS * Self.clientStarvationStressRatio ||
                snapshot.submittedFPS < targetFPS * Self.clientStarvationStressRatio ||
                snapshot.clientDroppedFrames > 0 ||
                !snapshot.decodeHealthy
        )

        let pairedPacerStress = pacerStress && (queueStress || dropStress)
        let pairedPacerSevere = pacerSevere && (queueSevere || dropSevere)
        let severeTransportPressure = queueSevere ||
            sendDelaySevere ||
            dropSevere ||
            pairedPacerSevere ||
            deliverySevere
        let sustainedTransportPressure = queueStress ||
            sendDelaySevere ||
            dropStress ||
            pairedPacerStress ||
            deliveryStress
        let transportPressureReason = Self.transportPressureReason(
            queueBytes: queueBytes,
            queueStress: queueStress,
            queueSevere: queueSevere,
            sendStartDelayAverageMs: sendStartDelayAverageMs,
            sendCompletionAverageMs: sendCompletionAverageMs,
            sendDelayStress: sendDelayStress,
            sendDelaySevere: sendDelaySevere,
            packetPacerAverageSleepMs: packetPacerAverageSleepMs,
            pairedPacerStress: pairedPacerStress,
            pairedPacerSevere: pairedPacerSevere,
            transportDropCount: transportDropCount,
            dropStress: dropStress,
            dropSevere: dropSevere,
            deliveryRatio: deliveryRatio,
            deliveryStress: deliveryStress,
            deliverySevere: deliverySevere,
            hostEncodedFPS: snapshot.hostEncodedFPS,
            receivedFPS: snapshot.receivedFPS
        )

        let targetFrameIntervalMs = 1000.0 / targetFPS
        let smoothEnoughForPromotion = snapshot.clientPresentationStallCount == 0 &&
            snapshot.clientWorstPresentationGapMs < max(250, targetFrameIntervalMs * 4) &&
            (
                snapshot.clientFrameIntervalP99Ms == 0 ||
                    snapshot.clientFrameIntervalP99Ms < max(120, targetFrameIntervalMs * 3)
            ) &&
            (
                snapshot.clientDisplayTickIntervalP99Ms == 0 ||
                    snapshot.clientDisplayTickIntervalP99Ms < max(120, targetFrameIntervalMs * 3)
            ) &&
            snapshot.clientPendingFrameAgeMs < max(80, targetFrameIntervalMs * 5)
        let suppressesProbePromotion = queueBytes > 0 ||
            transportDropCount > 0 ||
            sendDelayStress ||
            pacerStress ||
            clientStarvationStress
        let bottleneckKind = snapshot.bottleneckKind
        let clientBottleneckBlocksPromotion =
            bottleneckKind == .decodeBound ||
            bottleneckKind == .presentationBound ||
            !snapshot.decodeHealthy

        return Sample(
            hasSevereTransportPressure: severeTransportPressure,
            hasTransportPressure: severeTransportPressure || sustainedTransportPressure,
            isTransportClean: !severeTransportPressure && !sustainedTransportPressure,
            allowsProbePromotion: !suppressesProbePromotion &&
                !clientBottleneckBlocksPromotion &&
                smoothEnoughForPromotion,
            suppressesProbePromotion: suppressesProbePromotion,
            transportPressureReason: transportPressureReason
        )
    }

    private static func effectiveHealthFrameRate(
        requestedTargetFrameRate: Int,
        minimumHealthyFrameRate: Int?
    ) -> Int {
        let requestedTargetFrameRate = max(1, requestedTargetFrameRate)
        guard let minimumHealthyFrameRate else { return requestedTargetFrameRate }
        return min(requestedTargetFrameRate, max(1, minimumHealthyFrameRate))
    }

    private static func transportPressureReason(
        queueBytes: Int,
        queueStress: Bool,
        queueSevere: Bool,
        sendStartDelayAverageMs: Double,
        sendCompletionAverageMs: Double,
        sendDelayStress: Bool,
        sendDelaySevere: Bool,
        packetPacerAverageSleepMs: Double,
        pairedPacerStress: Bool,
        pairedPacerSevere: Bool,
        transportDropCount: UInt64,
        dropStress: Bool,
        dropSevere: Bool,
        deliveryRatio: Double,
        deliveryStress: Bool,
        deliverySevere: Bool,
        hostEncodedFPS: Double,
        receivedFPS: Double
    ) -> String? {
        if queueSevere || queueStress {
            return "host send queue \(Self.formatBytes(queueBytes))"
        }
        if dropSevere || dropStress {
            return "host packet drops \(transportDropCount)"
        }
        if sendDelaySevere || sendDelayStress {
            let startText = Self.formatMilliseconds(sendStartDelayAverageMs)
            let completionText = Self.formatMilliseconds(sendCompletionAverageMs)
            return "host send delay start=\(startText) completion=\(completionText)"
        }
        if pairedPacerSevere || pairedPacerStress {
            return "packet pacer \(Self.formatMilliseconds(packetPacerAverageSleepMs)) with queue/drop pressure"
        }
        if deliverySevere || deliveryStress {
            let ratio = Int((deliveryRatio * 100).rounded())
            let encodedText = hostEncodedFPS.formatted(.number.precision(.fractionLength(1)))
            let receivedText = receivedFPS.formatted(.number.precision(.fractionLength(1)))
            return "delivery collapse \(ratio)% received (host=\(encodedText)fps received=\(receivedText)fps)"
        }
        return nil
    }

    private static func formatBytes(_ bytes: Int) -> String {
        guard bytes >= 1024 else { return "\(bytes)B" }
        let kib = Double(bytes) / 1024.0
        if kib < 1024 {
            return "\(kib.formatted(.number.precision(.fractionLength(1))))KiB"
        }
        let mib = kib / 1024.0
        return "\(mib.formatted(.number.precision(.fractionLength(2))))MiB"
    }

    private static func formatMilliseconds(_ milliseconds: Double) -> String {
        "\(milliseconds.formatted(.number.precision(.fractionLength(1))))ms"
    }

    private static func hostPipelineHealthy(
        snapshot: MirageClientMetricsSnapshot,
        targetFPS: Double
    ) -> Bool {
        let captureFPS = max(
            snapshot.hostCaptureIngressFPS ?? 0,
            snapshot.hostCaptureFPS ?? 0,
            snapshot.hostEncodeAttemptFPS ?? 0
        )
        let encodedFPS = max(0, snapshot.hostEncodedFPS)
        return captureFPS >= targetFPS * 0.85 &&
            encodedFPS >= targetFPS * 0.75 &&
            snapshot.bottleneckKind != .captureBound &&
            snapshot.bottleneckKind != .encodeBound &&
            snapshot.bottleneckKind != .hostCadenceLimited
    }

    private static func clientCanVerifyTransport(
        snapshot: MirageClientMetricsSnapshot,
        targetFPS: Double
    ) -> Bool {
        guard snapshot.decodeHealthy else { return false }
        if snapshot.bottleneckKind == .decodeBound ||
            snapshot.bottleneckKind == .presentationBound {
            return false
        }
        let targetFrameIntervalMs = 1000.0 / targetFPS
        return snapshot.clientPresentationStallCount == 0 &&
            snapshot.clientWorstPresentationGapMs < max(250, targetFrameIntervalMs * 6)
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

    private static func worstSnapshot(
        from snapshots: [MirageClientMetricsSnapshot],
        minimumHealthyFrameRate: Int?
    ) -> MirageClientMetricsSnapshot {
        snapshots.max(by: { lhs, rhs in
            healthPriority(for: lhs, minimumHealthyFrameRate: minimumHealthyFrameRate) <
                healthPriority(for: rhs, minimumHealthyFrameRate: minimumHealthyFrameRate)
        }) ?? snapshots[0]
    }

    private static func healthPriority(
        for snapshot: MirageClientMetricsSnapshot,
        minimumHealthyFrameRate: Int?
    ) -> Int {
        let sample = sample(
            from: snapshot,
            minimumHealthyFrameRate: minimumHealthyFrameRate
        )
        var score = 0
        if sample.hasSevereTransportPressure {
            score += 1_000
        } else if sample.hasTransportPressure {
            score += 600
        }
        if sample.suppressesProbePromotion {
            score += 100
        }
        if !sample.allowsProbePromotion {
            score += 50
        }
        return score
    }
}
