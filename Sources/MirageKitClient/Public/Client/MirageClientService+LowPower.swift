import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
//
//  MirageClientService+LowPower.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//


@MainActor
extension MirageClientService {
    /// Starts monitoring client power state changes that may affect decoder low-power mode.
    func configureDecoderLowPowerMonitoring() {
        decoderPowerStateMonitor.start { [weak self] snapshot in
            guard let self else { return }
            decoderPowerStateSnapshot = snapshot
            scheduleDecoderLowPowerPolicyApply(reason: "power_state_change")
        }
    }

    /// Schedules decoder low-power policy evaluation on the main actor.
    func scheduleDecoderLowPowerPolicyApply(reason: String) {
        Task { @MainActor [weak self] in
            await self?.applyDecoderLowPowerPolicy(reason: reason)
        }
    }

    /// Applies the effective decoder low-power mode to active stream controllers.
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
