//
//  MirageReceiverHealthController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//
//  Receiver-health state machine for automatic bitrate adaptation.
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

        let snapshot = Self.worstSnapshot(from: snapshots, currentBitrateBps: currentBitrateBps)
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
        let decodedFPS = max(0, snapshot.decodedFPS)
        let receivedFPS = max(0, snapshot.receivedFPS)
        let presentedFPS = max(0, snapshot.presentedFPS)
        let uniquePresentedFPS = max(0, snapshot.uniquePresentedFPS)
        let effectiveFPS = decodedFPS > 0 && receivedFPS > 0 ? min(decodedFPS, receivedFPS) : max(decodedFPS, receivedFPS)
        let hostTemporaryDegradation = snapshot.hostTemporaryDegradationMode.map { $0 != .off } ?? false
        let hostBitrate = snapshot.hostCurrentBitrate ?? 0
        let bitratePressure = hostBitrate > 0 && snapshot.hostRequestedTargetBitrate.map { hostBitrate < Int(Double($0) * 0.90) } ?? false
        let decodePressure = snapshot.decodeHealthy == false || decodedFPS < 1.0
        let presentationPressure = presentedFPS < 1.0 || uniquePresentedFPS < 1.0
        let severe = decodePressure || presentationPressure || hostTemporaryDegradation
        let sustainedLoss = effectiveFPS < Double(targetFPS) * 0.80 ||
            receivedFPS < Double(targetFPS) * 0.80 ||
            (snapshot.hostTimeBelowTargetBitrateMs.map { $0 > 0 } ?? false) ||
            bitratePressure
        let healthy = !severe &&
            effectiveFPS >= Double(targetFPS) * 0.95 &&
            decodedFPS >= 1.0 &&
            presentedFPS >= 1.0 &&
            snapshot.decodeHealthy
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

    private static func worstSnapshot(
        from snapshots: [MirageClientMetricsSnapshot],
        currentBitrateBps: Int
    ) -> MirageClientMetricsSnapshot {
        snapshots.max(by: { lhs, rhs in
            healthPriority(for: lhs, currentBitrateBps: currentBitrateBps) < healthPriority(for: rhs, currentBitrateBps: currentBitrateBps)
        }) ?? snapshots[0]
    }

    private static func healthPriority(
        for snapshot: MirageClientMetricsSnapshot,
        currentBitrateBps: Int
    ) -> Int {
        let targetFPS = max(1, snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60)
        let decodedFPS = max(0, snapshot.decodedFPS)
        let receivedFPS = max(0, snapshot.receivedFPS)
        let presentedFPS = max(0, snapshot.presentedFPS)
        let uniquePresentedFPS = max(0, snapshot.uniquePresentedFPS)
        var score = 0

        if snapshot.decodeHealthy == false {
            score += 1_000
        }
        if decodedFPS < 1.0 {
            score += 900
        }
        if presentedFPS < 1.0 || uniquePresentedFPS < 1.0 {
            score += 800
        }
        if let mode = snapshot.hostTemporaryDegradationMode, mode != .off {
            score += 700
        }
        if receivedFPS < Double(targetFPS) * 0.8 {
            score += 500
        }
        if decodedFPS < Double(targetFPS) * 0.8 {
            score += 400
        }
        if let bitrate = snapshot.hostCurrentBitrate, bitrate > 0, bitrate < Int(Double(currentBitrateBps) * 0.9) {
            score += 200
        }
        if snapshot.hostTimeBelowTargetBitrateMs.map({ $0 > 0 }) ?? false {
            score += 150
        }

        return score
    }
}
