//
//  MirageReceiverHealthController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//
//  Receiver-health state machine for app-owned adaptive bitrate recovery.
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

    private static let minimumBitrateBps = 2_000_000
    private static let severeBackoffStep = 0.75
    private static let normalBackoffStep = 0.85
    private static let backoffCooldownSeconds: CFAbsoluteTime = 2
    private static let recoveryHealthySampleThreshold = 2
    private static let probeHealthySampleThreshold = 3
    private static let fastStartProbeHealthySampleThreshold = 2
    private static let probeIncreaseFloorBps = 40_000_000
    private static let probeIncreasePercent = 120
    private static let fastStartProbeIncreaseFloorBps = 80_000_000
    private static let fastStartProbeIncreasePercent = 135
    private static let successfulProbeCooldownSeconds: CFAbsoluteTime = 8
    private static let failedProbeCooldownSeconds: CFAbsoluteTime = 12
    private static let fastStartSuccessfulProbeCooldownSeconds: CFAbsoluteTime = 4
    private static let fastStartFailedProbeCooldownSeconds: CFAbsoluteTime = 6
    private static let fastStartDurationSeconds: CFAbsoluteTime = 12
    private static let encodedDeliveryStressRatio = 0.92
    private static let encodedDeliverySevereRatio = 0.75
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
    private var stressSampleCount: Int = 0
    private var nextProbeAllowedAt: CFAbsoluteTime = 0

    public init() {}

    public mutating func reset() {
        state = .stable
        lastTransitionAt = nil
        sessionStartedAt = nil
        healthySampleCount = 0
        stressSampleCount = 0
        nextProbeAllowedAt = 0
    }

    public mutating func noteProbeSucceeded(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        state = .stable
        lastTransitionAt = now
        healthySampleCount = 0
        stressSampleCount = 0
        nextProbeAllowedAt = now + probeCooldown(success: true, now: now)
    }

    public mutating func noteProbeFailed(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        state = .stable
        lastTransitionAt = now
        healthySampleCount = 0
        stressSampleCount = 0
        nextProbeAllowedAt = now + probeCooldown(success: false, now: now)
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
            stressSampleCount += 1
        } else {
            healthySampleCount += 1
            stressSampleCount = 0
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
        state = .backingOff
        lastTransitionAt = now
        healthySampleCount = 0
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

    private func probeTargetBitrate(
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
        guard healthySampleCount >= healthySampleThreshold else { return nil }
        guard currentBitrateBps < ceilingBps else { return nil }
        guard now >= nextProbeAllowedAt else { return nil }

        let probeIncreaseFloorBps = fastStartActive
            ? Self.fastStartProbeIncreaseFloorBps
            : Self.probeIncreaseFloorBps
        let probeIncreasePercent = fastStartActive
            ? Self.fastStartProbeIncreasePercent
            : Self.probeIncreasePercent
        let scaledIncrease = Int(
            (Int64(currentBitrateBps) * Int64(probeIncreasePercent) + 99) / 100
        )
        let nextBitrate = min(
            ceilingBps,
            max(currentBitrateBps + probeIncreaseFloorBps, scaledIncrease)
        )
        guard nextBitrate > currentBitrateBps else { return nil }
        return nextBitrate
    }

    private static func sample(
        from snapshot: MirageClientMetricsSnapshot
    ) -> Sample {
        let targetFPS = Double(max(1, snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60))
        let hostEncodedFPS = max(0, snapshot.hostEncodedFPS)
        let receivedFPS = max(0, snapshot.receivedFPS)
        let submittedFPS = max(0, snapshot.submittedFPS)
        let uniqueSubmittedFPS = max(0, snapshot.uniqueSubmittedFPS)
        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let captureIngressFPS = max(0, snapshot.hostCaptureIngressFPS ?? 0)
        let captureFPS = max(0, snapshot.hostCaptureFPS ?? 0)
        let encodeAttemptFPS = max(0, snapshot.hostEncodeAttemptFPS ?? 0)
        let transportDropCount = (snapshot.hostStalePacketDrops ?? 0) +
            (snapshot.hostGenerationAbortDrops ?? 0) +
            (snapshot.hostNonKeyframeHoldDrops ?? 0)
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
                transportDropSevereCount: Self.transportDropSevereCount,
                encodedFPS: hostEncodedFPS,
                deliveredFPS: receivedFPS,
                deliveryStressRatio: Self.encodedDeliveryStressRatio,
                deliverySevereRatio: Self.encodedDeliverySevereRatio
            )
        )
        let presentationBound = snapshot.bottleneckKind == .presentationBound
        let pacingOnlyStress = transportAssessment.isPacerOnlyStress
        let streamIsActive = max(
            hostEncodedFPS,
            max(receivedFPS, max(captureIngressFPS, max(captureFPS, encodeAttemptFPS)))
        ) > 0.5
        let severe = transportAssessment.isSevere && !pacingOnlyStress
        let sustainedLoss = transportAssessment.isStress && !pacingOnlyStress
        let healthy = !severe && !sustainedLoss
        let submittedCadenceHealthy = submittedFPS >= targetFPS * 0.95
        let uniqueSubmittedCadenceHealthy = uniqueSubmittedFPS >= targetFPS * 0.95
        let bottleneckAllowsProbePromotion: Bool = switch snapshot.bottleneckKind {
        case .unknown, .networkBound:
            true
        case .captureBound, .encodeBound, .decodeBound, .presentationBound, .mixed:
            false
        }
        return Sample(
            isSevere: severe,
            isStress: severe || sustainedLoss,
            isHealthy: healthy,
            allowsProbePromotion: streamIsActive &&
                snapshot.decodeHealthy &&
                submittedCadenceHealthy &&
                uniqueSubmittedCadenceHealthy &&
                bottleneckAllowsProbePromotion &&
                !presentationBound
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
        let hostEncodedFPS = max(0, snapshot.hostEncodedFPS)
        let receivedFPS = max(0, snapshot.receivedFPS)
        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let transportDropCount = (snapshot.hostStalePacketDrops ?? 0) +
            (snapshot.hostGenerationAbortDrops ?? 0) +
            (snapshot.hostNonKeyframeHoldDrops ?? 0)
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
                transportDropSevereCount: Self.transportDropSevereCount,
                encodedFPS: hostEncodedFPS,
                deliveredFPS: receivedFPS,
                deliveryStressRatio: Self.encodedDeliveryStressRatio,
                deliverySevereRatio: Self.encodedDeliverySevereRatio
            )
        )
        let pacingOnlyStress = transportAssessment.isPacerOnlyStress
        var score = 0

        if hostEncodedFPS > 0,
           receivedFPS < hostEncodedFPS * Self.encodedDeliverySevereRatio {
            score += 900
        }
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
        if hostEncodedFPS > 0,
           receivedFPS < hostEncodedFPS * Self.encodedDeliveryStressRatio {
            score += 500
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
