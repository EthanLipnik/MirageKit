//
//  StreamContext+DynamicCadence.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/12/26.
//
//  Clarity-first dynamic encode cadence for non-AWDL automatic streams.
//
//  The pressure ladder is: encode quality steps down to the clarity floor
//  first; once quality sits at that floor and pressure persists, frame rate
//  steps down (so each remaining frame keeps its bits); only severe survival
//  goes below the floor. Recovery walks the same ladder back up: quality
//  first, then frame rate once capacity for the next step is proven.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    private static let dynamicCadenceLadderMultipliers: [Double] = [1.0, 0.75, 0.5, 0.4]
    private static let dynamicCadenceMinimumFrameRate = 24
    private static let dynamicCadenceDemoteCooldownSeconds: CFAbsoluteTime = 2.0
    private static let dynamicCadencePromoteCooldownSeconds: CFAbsoluteTime = 5.0
    private static let dynamicCadenceDemoteQualitySlack: Float = 0.04
    private static let dynamicCadencePromoteQualityRatio: Float = 0.92
    private static let dynamicCadencePromoteHeadroomRatio = 0.80

    func applyDynamicCadenceIfNeeded(now: CFAbsoluteTime) async {
        guard isRunning,
              runtimeQualityAdjustmentEnabled,
              !mediaPathProfile.usesAwdlRadioPolicy,
              encoderConfig.codec != .proRes4444,
              !isResizing else {
            return
        }

        let ladder = dynamicCadenceLadder()
        guard ladder.count > 1 else { return }
        let currentRate = currentFrameRate

        if shouldDemoteDynamicCadence(now: now, ladder: ladder, currentRate: currentRate) {
            guard let target = ladder.first(where: { $0 < currentRate }) else { return }
            await applyDynamicCadenceStep(
                to: target,
                from: currentRate,
                direction: "demote",
                now: now
            )
            return
        }

        if let target = dynamicCadencePromoteTarget(now: now, ladder: ladder, currentRate: currentRate) {
            await applyDynamicCadenceStep(
                to: target,
                from: currentRate,
                direction: "promote",
                now: now
            )
        }
    }

    func applySustainedTransportAdmissionPressureIfNeeded(now: CFAbsoluteTime) async {
        guard transportAdmissionPressureState.isActive(now: now) else { return }
        guard now - transportAdmissionPressureState.lastStructuralStepTime >= 1.0 else { return }

        if mediaPathProfile.usesAwdlRadioPolicy {
            let applied = await applyAwdlHostStructuralAdaptationIfNeeded(
                reason: "transport-admission",
                at: now
            )
            if applied {
                transportAdmissionPressureState.lastStructuralStepTime = now
            }
            return
        }

        if await applyTransportAdmissionDynamicCadenceIfNeeded(now: now) {
            transportAdmissionPressureState.lastStructuralStepTime = now
            return
        }

        guard transportAdmissionPressureState.activeDuration(now: now) >= 2.0 else { return }
        if await applyTransportAdmissionScaleStepIfNeeded(now: now) {
            transportAdmissionPressureState.lastStructuralStepTime = now
        }
    }

    /// Pressure with quality already at the clarity floor means the quality
    /// lever is exhausted — trade frame rate next, never readability.
    private func shouldDemoteDynamicCadence(
        now: CFAbsoluteTime,
        ladder: [Int],
        currentRate: Int
    ) -> Bool {
        guard realtimePressureState == .pressured || realtimePressureState == .severe else {
            return false
        }
        guard currentRate > (ladder.last ?? currentRate) else { return false }
        guard activeQuality <= qualityFloor + Self.dynamicCadenceDemoteQualitySlack else {
            return false
        }
        guard now - lastDynamicCadenceStepTime >= Self.dynamicCadenceDemoteCooldownSeconds else {
            return false
        }
        return true
    }

    private func dynamicCadencePromoteTarget(
        now: CFAbsoluteTime,
        ladder: [Int],
        currentRate: Int
    ) -> Int? {
        guard realtimePressureState == .observing,
              let base = dynamicCadenceBaseFrameRate,
              currentRate < base,
              now - lastDynamicCadenceStepTime >= Self.dynamicCadencePromoteCooldownSeconds else {
            return nil
        }
        guard let target = ladder.reversed().first(where: { $0 > currentRate }) else {
            return nil
        }
        // Quality must have recovered near its mapped target at this rate —
        // promoting while quality is still depressed would trade clarity for fps.
        let qualityTarget = min(steadyQualityCeiling, configuredQualityCeiling)
        guard qualityTarget <= 0 ||
            activeQuality + 0.001 >= qualityTarget * Self.dynamicCadencePromoteQualityRatio else {
            return nil
        }
        // The next step multiplies P-frame wire demand by target/current; require
        // proven capacity headroom for it. With no recent P-frame evidence (idle
        // screens) promotion is cheap and the demote path re-fires if motion
        // proves otherwise.
        if let requiredBps = adaptivePFrameController.latestRequiredBitrateForCurrentQualityBps,
           requiredBps > 0 {
            let scaledRequirement = Double(requiredBps) * Double(target) / Double(max(1, currentRate))
            let capacityBps = Double(
                adaptivePFrameController.runtimeCeilingBps
                    ?? currentTargetBitrateBps
                    ?? encoderConfig.bitrate
                    ?? 0
            )
            guard capacityBps > 0,
                  scaledRequirement <= capacityBps / Self.dynamicCadencePromoteHeadroomRatio else {
                return nil
            }
        }
        return target
    }

    @discardableResult
    private func applyDynamicCadenceStep(
        to target: Int,
        from currentRate: Int,
        direction: String,
        now: CFAbsoluteTime
    ) async -> Bool {
        if dynamicCadenceBaseFrameRate == nil {
            dynamicCadenceBaseFrameRate = currentRate
        }
        isApplyingDynamicCadenceStep = true
        defer { isApplyingDynamicCadenceStep = false }
        do {
            try await updateFrameRate(target, updatesAwdlInteractiveCeiling: false)
            lastDynamicCadenceStepTime = now
            if target >= (dynamicCadenceBaseFrameRate ?? target) {
                dynamicCadenceBaseFrameRate = nil
            }
            if let onHostAdaptiveDesktopGeometryUpdate {
                await onHostAdaptiveDesktopGeometryUpdate(streamID)
            }
            MirageLogger.stream(
                "Dynamic cadence \(direction) for stream \(streamID): " +
                    "\(currentRate)fps -> \(target)fps " +
                    "(quality=\(activeQuality.formatted(.number.precision(.fractionLength(2)))) " +
                    "floor=\(qualityFloor.formatted(.number.precision(.fractionLength(2)))) " +
                    "state=\(realtimePressureState.rawValue))"
            )
            return true
        } catch {
            MirageLogger.error(.stream, error: error, message: "Dynamic cadence step failed: ")
            return false
        }
    }

    private func applyTransportAdmissionDynamicCadenceIfNeeded(now: CFAbsoluteTime) async -> Bool {
        guard isRunning,
              runtimeQualityAdjustmentEnabled,
              !mediaPathProfile.usesAwdlRadioPolicy,
              encoderConfig.codec != .proRes4444,
              !isResizing else {
            return false
        }

        let ladder = dynamicCadenceLadder()
        guard ladder.count > 1,
              currentFrameRate > (ladder.last ?? currentFrameRate),
              now - lastDynamicCadenceStepTime >= 1.0,
              let target = ladder.first(where: { $0 < currentFrameRate }) else {
            return false
        }
        return await applyDynamicCadenceStep(
            to: target,
            from: currentFrameRate,
            direction: "transport-admission-demote",
            now: now
        )
    }

    private func applyTransportAdmissionScaleStepIfNeeded(now: CFAbsoluteTime) async -> Bool {
        guard isRunning,
              runtimeQualityAdjustmentEnabled,
              !mediaPathProfile.usesAwdlRadioPolicy,
              encoderConfig.codec != .proRes4444,
              !isResizing else {
            return false
        }

        let ladder = dynamicCadenceLadder()
        guard currentFrameRate <= (ladder.last ?? currentFrameRate) else { return false }
        let baseScale = requestedStreamScale
        guard baseScale > 0 else { return false }
        let currentMultiplier = Double(streamScale / baseScale)
        let targetMultiplier: Double
        if currentMultiplier > 0.876 {
            targetMultiplier = 0.875
        } else if currentMultiplier > 0.751 {
            targetMultiplier = 0.75
        } else {
            return false
        }

        do {
            try await updateEmergencyRecoveryScale(
                CGFloat(Double(baseScale) * targetMultiplier),
                reason: "transport-admission",
                advancesDimensionToken: true
            )
            if let onHostAdaptiveDesktopGeometryUpdate {
                await onHostAdaptiveDesktopGeometryUpdate(streamID)
            }
            await encoder?.forceKeyframe()
            MirageLogger.metrics(
                "Transport admission structural scale step for stream \(streamID): " +
                    "targetMultiplier=\(targetMultiplier.formatted(.number.precision(.fractionLength(3))))"
            )
            return true
        } catch {
            MirageLogger.error(.stream, error: error, message: "Transport admission scale step failed: ")
            return false
        }
    }

    /// Descending ladder anchored at the stream's base rate, never below the
    /// dynamic minimum. A 60 fps stream steps 60 → 45 → 30 → 24.
    private func dynamicCadenceLadder() -> [Int] {
        let base = dynamicCadenceBaseFrameRate ?? currentFrameRate
        guard base > Self.dynamicCadenceMinimumFrameRate else { return [base] }
        var ladder: [Int] = []
        for multiplier in Self.dynamicCadenceLadderMultipliers {
            let step = max(
                Self.dynamicCadenceMinimumFrameRate,
                Int((Double(base) * multiplier).rounded())
            )
            if ladder.last != step { ladder.append(step) }
        }
        return ladder
    }

    /// External frame-rate changes (client requests, mode changes) re-anchor the
    /// ladder; only governor-initiated steps preserve the base to promote back to.
    func noteExternalFrameRateChange() {
        guard !isApplyingDynamicCadenceStep else { return }
        dynamicCadenceBaseFrameRate = nil
        lastDynamicCadenceStepTime = 0
    }
}
#endif
