//
//  StreamContext+DynamicCadence.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/12/26.
//
//  Intent-aware dynamic encode cadence for non-AWDL automatic streams.
//
//  Motion pressure spends quality before cadence so latency stays fresh.
//  Still/readability pressure can spend cadence first so each delivered frame
//  keeps enough bits to remain readable.
//

import CoreFoundation
import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    private static let dynamicCadenceLadderMultipliers: [Double] = [1.0, 0.75, 0.5, 0.4]
    private static let dynamicCadenceMinimumFrameRate = 24
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
            if let onHostAdaptiveDesktopCadenceUpdate {
                await onHostAdaptiveDesktopCadenceUpdate(streamID)
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
        let policy = activeFrameFreshnessPolicy
        let senderTelemetry = await packetSender?.telemetrySnapshot
        let pressureSnapshot = adaptiveTransportPressureSnapshot(
            senderTelemetry: senderTelemetry,
            now: now
        )
        let contract = currentStreamQualityContract()
        guard streamQualityGovernor.allowsDynamicCadenceDemotion(
            snapshot: pressureSnapshot,
            contract: contract,
            now: now
        ) else {
            return false
        }
        let governorDecision = latestStreamQualityDecision()
        let governorAllowsMotionCadence = governorDecision.cause == .motion &&
            governorDecision.selectedLever == .reduceCadence
        if mediaPathProfile.usesLocalBulkTransportPolicy,
           !governorAllowsMotionCadence,
           !adaptiveFrameCoordinator.allowsTransportAdmissionStructuralStep(pressureSnapshot) {
            return false
        }
        let admissionPressureState: HostAdaptivePFrameController.PressureState = switch transportAdmissionPressureState.mode {
        case .hardThrottle:
            .severe
        case .softThrottle:
            .pressured
        case .normal:
            realtimePressureState
        }
        let transportPressureActionable = adaptiveFrameCoordinator.transportPressureIsActionable(pressureSnapshot) ||
            governorAllowsMotionCadence
        let cadenceQualityFloor = governorAllowsMotionCadence
            ? contract.localMotionQualityFloor
            : qualityFloor
        guard adaptiveFrameCoordinator.allowsDynamicCadenceDemotion(
            pressureState: admissionPressureState,
            activeQuality: activeQuality,
            qualityFloor: cadenceQualityFloor,
            sourceStill: sourceIsStill(now: now, policy: policy),
            inputActive: inputIsActive(now: now, policy: policy),
            receiverState: adaptiveReceiverEvidenceState(now: now),
            transportPressureActionable: transportPressureActionable,
            transportAdmissionActiveDuration: transportAdmissionPressureState.activeDuration(now: now)
        ) else {
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
        let senderTelemetry = await packetSender?.telemetrySnapshot
        let pressureSnapshot = adaptiveTransportPressureSnapshot(senderTelemetry: senderTelemetry, now: now)
        guard streamQualityGovernor.allowsStructuralScaleDemotion(
            snapshot: pressureSnapshot,
            contract: currentStreamQualityContract(),
            now: now
        ),
        adaptiveFrameCoordinator.allowsTransportAdmissionStructuralStep(pressureSnapshot) else {
            return false
        }
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
