//
//  ClientLowPowerPreferencePersistenceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

import MirageKit
import Testing

@Suite("Client Low-Power Preference Persistence")
struct ClientLowPowerPreferencePersistenceTests {
    @Test("Persisted battery-only preference coerces to auto when battery policy is unavailable")
    func persistedBatteryOnlyPreferenceCoercesWhenUnsupported() {
        let storedRawValue = MirageCodecLowPowerModePreference.onlyOnBattery.rawValue
        let restoredPreference = MirageCodecLowPowerModePreference(rawValue: storedRawValue)

        #expect(restoredPreference == .onlyOnBattery)
        #expect(restoredPreference?.resolvedForBatteryPolicySupport(false) == .auto)
    }

    @Test("Persisted battery-only preference stays battery-only when support exists")
    func persistedBatteryOnlyPreferenceRemainsWhenSupported() {
        let storedRawValue = MirageCodecLowPowerModePreference.onlyOnBattery.rawValue
        let restoredPreference = MirageCodecLowPowerModePreference(rawValue: storedRawValue)

        #expect(restoredPreference?.resolvedForBatteryPolicySupport(true) == .onlyOnBattery)
    }
}
