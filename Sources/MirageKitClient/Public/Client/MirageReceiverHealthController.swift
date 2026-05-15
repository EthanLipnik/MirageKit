//
//  MirageReceiverHealthController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

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
    }

    /// Advances receiver-health policy using multiple stream snapshots.
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

    /// Advances receiver-health policy using one stream snapshot.
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
        let effectiveAllowsBackoff = allowsBackoff &&
            (!isFastStartActive(now: now) || sample.hasProvenTransportLoss)
        updateSampleCounters(sample: sample, now: now, allowsBackoff: effectiveAllowsBackoff)

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
            if effectiveAllowsBackoff, shouldBackOff(sample: sample, now: now) {
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
        resetSampleCounters()
        nextProbeAllowedAt = max(nextProbeAllowedAt, now + Self.backoffCooldownSeconds)
        guard nextBitrate < currentBitrateBps else { return .none }
        return .backoff(targetBitrateBps: nextBitrate)
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
