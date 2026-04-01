//
//  MirageReceiverHealthController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//
//  Receiver-health state machine for app-owned adaptive bitrate recovery.
//

import Foundation
import MirageKit

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
    private static let probeQualityTarget = 0.80
    private static let probeIncreaseFloorBps = 40_000_000
    private static let probeIncreaseScale = 1.20
    private static let successfulProbeCooldownSeconds: CFAbsoluteTime = 8
    private static let failedProbeCooldownSeconds: CFAbsoluteTime = 12
    private static let receivedFPSStressRatio = 0.92
    private static let receivedFPSSevereRatio = 0.75
    private static let receivedFPSHealthyRatio = 0.97
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
    private var healthySampleCount: Int = 0
    private var stressSampleCount: Int = 0
    private var nextProbeAllowedAt: CFAbsoluteTime = 0

    public init() {}

    public mutating func reset() {
        state = .stable
        lastTransitionAt = nil
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
        nextProbeAllowedAt = now + Self.successfulProbeCooldownSeconds
    }

    public mutating func noteProbeFailed(
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        state = .stable
        lastTransitionAt = now
        healthySampleCount = 0
        stressSampleCount = 0
        nextProbeAllowedAt = now + Self.failedProbeCooldownSeconds
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
        let minimumProbeActiveQuality = snapshots
            .filter(\.hasHostMetrics)
            .map(\.hostActiveQuality)
            .min()
        return advance(
            snapshot: snapshot,
            currentBitrateBps: currentBitrateBps,
            ceilingBps: ceilingBps,
            minimumProbeActiveQuality: minimumProbeActiveQuality,
            now: now
        )
    }

    public mutating func advance(
        snapshot: MirageClientMetricsSnapshot?,
        currentBitrateBps: Int,
        ceilingBps: Int,
        minimumProbeActiveQuality: Double? = nil,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Action {
        guard currentBitrateBps > 0, ceilingBps > 0 else {
            reset()
            return .none
        }
        guard let snapshot else {
            reset()
            return .none
        }

        let sample = Self.sample(
            from: snapshot,
            minimumProbeActiveQuality: minimumProbeActiveQuality
        )

        if sample.isHealthy {
            healthySampleCount += 1
            stressSampleCount = 0
        } else {
            healthySampleCount = 0
            stressSampleCount += 1
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
        let probeActiveQuality: Double
    }

    private func probeTargetBitrate(
        sample: Sample,
        currentBitrateBps: Int,
        ceilingBps: Int,
        now: CFAbsoluteTime
    ) -> Int? {
        guard sample.isHealthy else { return nil }
        guard healthySampleCount >= Self.probeHealthySampleThreshold else { return nil }
        guard currentBitrateBps < ceilingBps else { return nil }
        guard sample.probeActiveQuality < Self.probeQualityTarget else { return nil }
        guard now >= nextProbeAllowedAt else { return nil }

        let scaledIncrease = Int((Double(currentBitrateBps) * Self.probeIncreaseScale).rounded(.up))
        let nextBitrate = min(
            ceilingBps,
            max(currentBitrateBps + Self.probeIncreaseFloorBps, scaledIncrease)
        )
        guard nextBitrate > currentBitrateBps else { return nil }
        return nextBitrate
    }

    private static func sample(
        from snapshot: MirageClientMetricsSnapshot,
        minimumProbeActiveQuality: Double?
    ) -> Sample {
        let targetFPS = max(1, snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60)
        let receivedFPS = max(0, snapshot.receivedFPS)
        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let transportDropCount = (snapshot.hostStalePacketDrops ?? 0) +
            (snapshot.hostGenerationAbortDrops ?? 0) +
            (snapshot.hostNonKeyframeHoldDrops ?? 0)

        let severe = receivedFPS < Double(targetFPS) * Self.receivedFPSSevereRatio ||
            queueBytes >= Self.sendQueueSevereBytes ||
            sendStartDelayAverageMs >= Self.sendStartDelaySevereMs ||
            sendCompletionAverageMs >= Self.sendCompletionSevereMs ||
            packetPacerAverageSleepMs >= Self.packetPacerSevereMs ||
            transportDropCount >= Self.transportDropSevereCount
        let sustainedLoss = receivedFPS < Double(targetFPS) * Self.receivedFPSStressRatio ||
            queueBytes >= Self.sendQueueStressBytes ||
            sendStartDelayAverageMs >= Self.sendStartDelayStressMs ||
            sendCompletionAverageMs >= Self.sendCompletionStressMs ||
            packetPacerAverageSleepMs >= Self.packetPacerStressMs ||
            transportDropCount > 0
        let healthy = !severe &&
            receivedFPS >= Double(targetFPS) * Self.receivedFPSHealthyRatio &&
            queueBytes < Self.sendQueueStressBytes &&
            sendStartDelayAverageMs < Self.sendStartDelayStressMs &&
            sendCompletionAverageMs < Self.sendCompletionStressMs &&
            packetPacerAverageSleepMs < Self.packetPacerStressMs &&
            transportDropCount == 0
        let probeActiveQuality = max(
            0,
            min(
                1,
                minimumProbeActiveQuality ?? snapshot.hostActiveQuality
            )
        )

        return Sample(
            isSevere: severe,
            isStress: severe || sustainedLoss,
            isHealthy: healthy,
            probeActiveQuality: probeActiveQuality
        )
    }

    private static func worstSnapshot(from snapshots: [MirageClientMetricsSnapshot]) -> MirageClientMetricsSnapshot {
        snapshots.max(by: { lhs, rhs in
            healthPriority(for: lhs) < healthPriority(for: rhs)
        }) ?? snapshots[0]
    }

    private static func healthPriority(for snapshot: MirageClientMetricsSnapshot) -> Int {
        let targetFPS = max(1, snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60)
        let receivedFPS = max(0, snapshot.receivedFPS)
        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let transportDropCount = (snapshot.hostStalePacketDrops ?? 0) +
            (snapshot.hostGenerationAbortDrops ?? 0) +
            (snapshot.hostNonKeyframeHoldDrops ?? 0)
        var score = 0

        if receivedFPS < Double(targetFPS) * Self.receivedFPSSevereRatio {
            score += 900
        }
        if queueBytes >= Self.sendQueueSevereBytes {
            score += 800
        }
        if sendStartDelayAverageMs >= Self.sendStartDelaySevereMs ||
            sendCompletionAverageMs >= Self.sendCompletionSevereMs {
            score += 700
        }
        if packetPacerAverageSleepMs >= Self.packetPacerSevereMs {
            score += 650
        }
        if transportDropCount >= Self.transportDropSevereCount {
            score += 600
        }
        if receivedFPS < Double(targetFPS) * Self.receivedFPSStressRatio {
            score += 500
        }
        if queueBytes >= Self.sendQueueStressBytes {
            score += 400
        }
        if sendStartDelayAverageMs >= Self.sendStartDelayStressMs ||
            sendCompletionAverageMs >= Self.sendCompletionStressMs {
            score += 300
        }
        if packetPacerAverageSleepMs >= Self.packetPacerStressMs {
            score += 250
        }
        if transportDropCount > 0 {
            score += 200
        }

        return score
    }
}
