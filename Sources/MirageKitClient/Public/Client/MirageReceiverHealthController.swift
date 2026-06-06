//
//  MirageReceiverHealthController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

/// Tracks receiver-side health samples and chooses bitrate backoff or promotion probes.
public struct MirageReceiverHealthController: Sendable {
    /// Current adaptive receiver-health state.
    public enum State: String, Sendable, Equatable {
        /// Receiver samples are healthy enough to keep or raise bitrate.
        case stable
        /// Receiver samples indicate pressure and the controller is reducing bitrate.
        case backingOff
    }

    /// Bitrate action selected after evaluating recent receiver samples.
    public enum Action: Sendable, Equatable {
        /// Keep the current bitrate.
        case none
        /// Reduce bitrate to the supplied target.
        case backoff(targetBitrateBps: Int)
        /// Probe the supplied higher bitrate.
        case probe(targetBitrateBps: Int)
    }

    /// Strategy for recovering from a learned promotion ceiling after failed probes.
    public enum PromotionRecoveryMode: String, Sendable, Equatable {
        /// Recover slowly once the current route has settled below the learned ceiling.
        case settledCeiling
        /// Recover conservatively on proximity wireless routes that can remain connected while degrading.
        case conservativeProximity
        /// Recover more aggressively when route changes suggest the ceiling may be stale.
        case dynamicRoute
    }

    /// Current receiver health state.
    public internal(set) var state: State = .stable

    /// Policy for recovering a promotion ceiling after failed probes.
    public var promotionRecoveryMode: PromotionRecoveryMode

    /// Most recent transport-pressure reason that influenced receiver health.
    public private(set) var lastTransportPressureReason: String?

    var lastTransitionAt: CFAbsoluteTime?
    var sessionStartedAt: CFAbsoluteTime?
    var healthySampleCount: Int = 0
    var promotionHealthySampleCount: Int = 0
    var stressSampleCount: Int = 0
    var nextProbeAllowedAt: CFAbsoluteTime = 0
    var promotionCeilingBps: Int?
    var pendingPromotion: ReceiverPendingPromotion?
    var receiverMediaFailureTimes: [CFAbsoluteTime] = []

    /// Creates a receiver health controller.
    public init(
        promotionRecoveryMode: PromotionRecoveryMode = .settledCeiling,
        promotionCeilingBps: Int? = nil
    ) {
        self.promotionRecoveryMode = promotionRecoveryMode
        self.promotionCeilingBps = promotionCeilingBps
    }

    /// Resets sample counters, pending probes, and pressure state.
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
        resetSampleCounters()
        nextProbeAllowedAt = preservedNextProbeAllowedAt
        promotionCeilingBps = preservedPromotionCeilingBps
        pendingPromotion = nil
        receiverMediaFailureTimes.removeAll(keepingCapacity: false)
    }

    /// Advances receiver-health policy using multiple stream snapshots.
    public mutating func advance(
        snapshots: [MirageDiagnostics.MirageClientMetricsSnapshot],
        currentBitrateBps: Int,
        ceilingBps: Int,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        allowsNewProbe: Bool = true,
        allowsBackoff: Bool = true,
        prefersQualityRecovery: Bool = false,
        minimumHealthyFrameRate: Int? = nil,
        minimumBitrateFloorBps: Int = 12_000_000,
        usesCadenceDeliveryPressure: Bool = true
    ) -> Action {
        guard currentBitrateBps > 0, ceilingBps > 0, !snapshots.isEmpty else {
            reset()
            return .none
        }
        return advance(
            snapshot: Self.worstSnapshot(
                from: snapshots,
                minimumHealthyFrameRate: minimumHealthyFrameRate,
                usesCadenceDeliveryPressure: usesCadenceDeliveryPressure
            ),
            currentBitrateBps: currentBitrateBps,
            ceilingBps: ceilingBps,
            now: now,
            allowsNewProbe: allowsNewProbe,
            allowsBackoff: allowsBackoff,
            prefersQualityRecovery: prefersQualityRecovery,
            minimumHealthyFrameRate: minimumHealthyFrameRate,
            minimumBitrateFloorBps: minimumBitrateFloorBps,
            usesCadenceDeliveryPressure: usesCadenceDeliveryPressure
        )
    }

    /// Advances receiver-health policy using one stream snapshot.
    public mutating func advance(
        snapshot: MirageDiagnostics.MirageClientMetricsSnapshot?,
        currentBitrateBps: Int,
        ceilingBps: Int,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        allowsNewProbe: Bool = true,
        allowsBackoff: Bool = true,
        prefersQualityRecovery: Bool = false,
        minimumHealthyFrameRate: Int? = nil,
        minimumBitrateFloorBps: Int = 12_000_000,
        usesCadenceDeliveryPressure: Bool = true
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
            minimumHealthyFrameRate: minimumHealthyFrameRate,
            usesCadenceDeliveryPressure: usesCadenceDeliveryPressure
        )
        lastTransportPressureReason = sample.transportPressureReason
        let effectiveAllowsBackoff = allowsBackoff &&
            (!isFastStartActive(now: now) || sample.hasProvenTransportLoss)
        updateSampleCounters(sample: sample, now: now, allowsBackoff: effectiveAllowsBackoff)

        if let receiverFailureAction = receiverMediaDeliveryFailureBackoffAction(
            sample: sample,
            currentBitrateBps: currentBitrateBps,
            now: now,
            allowsBackoff: effectiveAllowsBackoff,
            minimumBitrateFloorBps: minimumBitrateFloorBps
        ) {
            return receiverFailureAction
        }

        if let promotionAction = advancePendingPromotion(
            sample: sample,
            currentBitrateBps: currentBitrateBps,
            now: now,
            allowsBackoff: effectiveAllowsBackoff
        ) {
            return promotionAction
        }
        if pendingPromotion != nil {
            return .none
        }

        switch state {
        case .stable:
            if effectiveAllowsBackoff, shouldBackOff(sample: sample, now: now) {
                return applyBackoff(
                    sample: sample,
                    currentBitrateBps: currentBitrateBps,
                    now: now,
                    minimumBitrateFloorBps: minimumBitrateFloorBps
                )
            }
            return probeActionIfReady(
                sample: sample,
                currentBitrateBps: currentBitrateBps,
                ceilingBps: ceilingBps,
                now: now,
                allowsNewProbe: allowsNewProbe,
                prefersQualityRecovery: prefersQualityRecovery
            )

        case .backingOff:
            if effectiveAllowsBackoff, shouldBackOff(sample: sample, now: now) {
                return applyBackoff(
                    sample: sample,
                    currentBitrateBps: currentBitrateBps,
                    now: now,
                    minimumBitrateFloorBps: minimumBitrateFloorBps
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
                    allowsNewProbe: allowsNewProbe,
                    prefersQualityRecovery: prefersQualityRecovery
                )
            }
        }

        return .none
    }

    private mutating func updateSampleCounters(
        sample: ReceiverHealthSample,
        now: CFAbsoluteTime,
        allowsBackoff: Bool
    ) {
        if sample.suppressesProbePromotion {
            nextProbeAllowedAt = max(nextProbeAllowedAt, now + Self.probeSuppressionCooldownSeconds)
        }

        if sample.hasTransportPressure, allowsBackoff {
            healthySampleCount = 0
            promotionHealthySampleCount = 0
            stressSampleCount += 1
        } else if sample.hasTransportPressure {
            healthySampleCount = 0
            promotionHealthySampleCount = 0
            stressSampleCount = 0
            pendingPromotion = nil
        } else if sample.isTransportClean {
            healthySampleCount += 1
            if sample.allowsProbePromotion {
                promotionHealthySampleCount += 1
            } else {
                promotionHealthySampleCount = 0
            }
            stressSampleCount = 0
        } else {
            healthySampleCount = 0
            promotionHealthySampleCount = 0
            stressSampleCount = 0
        }
    }

    private mutating func applyBackoff(
        sample: ReceiverHealthSample,
        currentBitrateBps: Int,
        now: CFAbsoluteTime,
        minimumBitrateFloorBps: Int
    ) -> Action {
        let floorBps = max(Self.minimumBitrateBps, minimumBitrateFloorBps)
        let step = if sample.hasSevereReceiverMediaLatencyPressure {
            Self.receiverMediaRepeatedBackoffStep
        } else if sample.hasReceiverMediaLatencyPressure {
            Self.receiverMediaFirstBackoffStep
        } else {
            sample.hasSevereTransportPressure ? Self.severeBackoffStep : Self.normalBackoffStep
        }
        let nextBitrate = max(floorBps, Int(Double(currentBitrateBps) * step))
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
        resetSampleCounters()
        nextProbeAllowedAt = max(nextProbeAllowedAt, now + Self.backoffCooldownSeconds)
        guard nextBitrate < currentBitrateBps else { return .none }
        return .backoff(targetBitrateBps: nextBitrate)
    }

    private mutating func receiverMediaDeliveryFailureBackoffAction(
        sample: ReceiverHealthSample,
        currentBitrateBps: Int,
        now: CFAbsoluteTime,
        allowsBackoff: Bool,
        minimumBitrateFloorBps: Int
    ) -> Action? {
        guard sample.hasReceiverMediaDeliveryFailure else { return nil }
        recordReceiverMediaDeliveryFailure(now: now)
        guard allowsBackoff else { return nil }
        if let lastTransitionAt,
           now - lastTransitionAt < receiverMediaBackoffCooldownSeconds {
            return nil
        }
        let repeatedFailure = receiverMediaFailureTimes.count >= 2
        let floorBps = max(Self.minimumBitrateBps, minimumBitrateFloorBps)
        let nextBitrate: Int
        if promotionRecoveryMode == .conservativeProximity,
           repeatedFailure,
           sample.hasSevereTransportPressure {
            nextBitrate = floorBps
        } else {
            let step = receiverMediaBackoffStep(repeatedFailure: repeatedFailure)
            nextBitrate = max(floorBps, Int(Double(currentBitrateBps) * step))
        }
        let promotionCeilingStep = repeatedFailure
            ? Self.severeBackoffPromotionCeilingStep
            : Self.normalBackoffPromotionCeilingStep
        rememberPromotionCeiling(
            max(nextBitrate, Int(Double(currentBitrateBps) * promotionCeilingStep))
        )
        state = .backingOff
        lastTransitionAt = now
        resetSampleCounters()
        pendingPromotion = nil
        nextProbeAllowedAt = max(nextProbeAllowedAt, now + receiverMediaProbeHoldSeconds)
        guard nextBitrate < currentBitrateBps else { return nil }
        return .backoff(targetBitrateBps: nextBitrate)
    }

    private mutating func recordReceiverMediaDeliveryFailure(now: CFAbsoluteTime) {
        receiverMediaFailureTimes.append(now)
        let cutoff = now - Self.receiverMediaFailureWindowSeconds
        while let first = receiverMediaFailureTimes.first, first < cutoff {
            receiverMediaFailureTimes.removeFirst()
        }
    }

    private var receiverMediaBackoffCooldownSeconds: CFAbsoluteTime {
        promotionRecoveryMode == .conservativeProximity ? 2 : Self.receiverMediaBackoffCooldownSeconds
    }

    private var receiverMediaProbeHoldSeconds: CFAbsoluteTime {
        promotionRecoveryMode == .conservativeProximity ? 30 : Self.receiverMediaBackoffCooldownSeconds
    }

    private func receiverMediaBackoffStep(repeatedFailure: Bool) -> Double {
        if promotionRecoveryMode == .conservativeProximity {
            return repeatedFailure ? 0.60 : 0.70
        }
        return repeatedFailure ? Self.receiverMediaRepeatedBackoffStep : Self.receiverMediaFirstBackoffStep
    }

    private func shouldBackOff(
        sample: ReceiverHealthSample,
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

    /// Clears accumulated healthy, promotion, and stress sample streaks.
    mutating func resetSampleCounters() {
        healthySampleCount = 0
        promotionHealthySampleCount = 0
        stressSampleCount = 0
    }
}
