//
//  MirageHostService+LowPower.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func configureEncoderLowPowerMonitoring() {
        encoderPowerStateMonitor.start { [weak self] snapshot in
            guard let self else { return }
            encoderPowerStateSnapshot = snapshot
            scheduleEncoderLowPowerPolicyApply(reason: "power_state_change")
        }
    }

    func scheduleEncoderLowPowerPolicyApply(reason: String) {
        Task { @MainActor [weak self] in
            await self?.applyEncoderLowPowerPolicy(reason: reason)
        }
    }

    private func applyEncoderLowPowerPolicy(reason: String) async {
        let supportsBatteryPolicy = encoderPowerStateSnapshot.supportsBatteryState
        if encoderLowPowerSupportsBatteryPolicy != supportsBatteryPolicy {
            encoderLowPowerSupportsBatteryPolicy = supportsBatteryPolicy
            onEncoderLowPowerBatteryPolicySupportChanged?(supportsBatteryPolicy)
        }

        let effectiveLowPowerEnabled = encoderLowPowerModePreference.resolvesToLowPowerMode(
            isSystemLowPowerModeEnabled: encoderPowerStateSnapshot.isSystemLowPowerModeEnabled,
            isOnBattery: encoderPowerStateSnapshot.isOnBattery
        )
        guard isEncoderLowPowerModeActive != effectiveLowPowerEnabled else { return }

        isEncoderLowPowerModeActive = effectiveLowPowerEnabled
        let batteryText = if let onBattery = encoderPowerStateSnapshot.isOnBattery {
            String(onBattery)
        } else {
            "unknown"
        }
        MirageLogger.host(
            "Host encoder low-power mode: \(effectiveLowPowerEnabled ? "enabled" : "disabled") " +
                "(reason=\(reason), preference=\(encoderLowPowerModePreference.rawValue), " +
                "systemLowPower=\(encoderPowerStateSnapshot.isSystemLowPowerModeEnabled), onBattery=\(batteryText))"
        )

        let activeContexts = Array(streamsByID.values)
        for context in activeContexts {
            await context.setEncoderLowPowerEnabled(effectiveLowPowerEnabled)
        }
    }
}
#endif
