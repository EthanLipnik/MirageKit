//
//  MirageClientService+LowPower.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func configureDecoderLowPowerMonitoring() {
        decoderPowerStateMonitor.start { [weak self] snapshot in
            guard let self else { return }
            decoderPowerStateSnapshot = snapshot
            scheduleDecoderLowPowerPolicyApply(reason: "power_state_change")
        }
    }

    func scheduleDecoderLowPowerPolicyApply(reason: String) {
        Task { @MainActor [weak self] in
            await self?.applyDecoderLowPowerPolicy(reason: reason)
        }
    }

    private func applyDecoderLowPowerPolicy(reason: String) async {
        let supportsBatteryPolicy = decoderPowerStateSnapshot.supportsBatteryState
        if decoderLowPowerSupportsBatteryPolicy != supportsBatteryPolicy {
            decoderLowPowerSupportsBatteryPolicy = supportsBatteryPolicy
            onDecoderLowPowerBatteryPolicySupportChanged?(supportsBatteryPolicy)
        }

        let effectiveLowPowerEnabled = decoderLowPowerModePreference.resolvesToLowPowerMode(
            isSystemLowPowerModeEnabled: decoderPowerStateSnapshot.isSystemLowPowerModeEnabled,
            isOnBattery: decoderPowerStateSnapshot.isOnBattery
        )
        guard isDecoderLowPowerModeActive != effectiveLowPowerEnabled else { return }

        isDecoderLowPowerModeActive = effectiveLowPowerEnabled
        let batteryText = if let onBattery = decoderPowerStateSnapshot.isOnBattery {
            String(onBattery)
        } else {
            "unknown"
        }
        MirageLogger.client(
            "Client decoder low-power mode: \(effectiveLowPowerEnabled ? "enabled" : "disabled") " +
                "(reason=\(reason), preference=\(decoderLowPowerModePreference.rawValue), " +
                "systemLowPower=\(decoderPowerStateSnapshot.isSystemLowPowerModeEnabled), onBattery=\(batteryText))"
        )

        let controllers = Array(controllersByStream.values)
        for controller in controllers {
            await controller.setDecoderLowPowerEnabled(effectiveLowPowerEnabled)
        }
    }
}
