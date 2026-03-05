//
//  MirageCodecLowPowerModePreferenceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Codec Low-Power Preference")
struct MirageCodecLowPowerModePreferenceTests {
    @Test("Auto follows the system low-power mode state")
    func autoFollowsSystemLowPowerMode() {
        #expect(
            MirageCodecLowPowerModePreference.auto.resolvesToLowPowerMode(
                isSystemLowPowerModeEnabled: false,
                isOnBattery: nil
            ) == false
        )
        #expect(
            MirageCodecLowPowerModePreference.auto.resolvesToLowPowerMode(
                isSystemLowPowerModeEnabled: true,
                isOnBattery: nil
            ) == true
        )
    }

    @Test("On always enables low-power mode")
    func onAlwaysEnablesLowPowerMode() {
        #expect(
            MirageCodecLowPowerModePreference.on.resolvesToLowPowerMode(
                isSystemLowPowerModeEnabled: false,
                isOnBattery: nil
            ) == true
        )
        #expect(
            MirageCodecLowPowerModePreference.on.resolvesToLowPowerMode(
                isSystemLowPowerModeEnabled: false,
                isOnBattery: false
            ) == true
        )
        #expect(
            MirageCodecLowPowerModePreference.on.resolvesToLowPowerMode(
                isSystemLowPowerModeEnabled: true,
                isOnBattery: true
            ) == true
        )
    }

    @Test("Only on battery requires explicit battery power state")
    func onlyOnBatteryRequiresBatteryState() {
        #expect(
            MirageCodecLowPowerModePreference.onlyOnBattery.resolvesToLowPowerMode(
                isSystemLowPowerModeEnabled: false,
                isOnBattery: true
            ) == true
        )
        #expect(
            MirageCodecLowPowerModePreference.onlyOnBattery.resolvesToLowPowerMode(
                isSystemLowPowerModeEnabled: true,
                isOnBattery: false
            ) == false
        )
        #expect(
            MirageCodecLowPowerModePreference.onlyOnBattery.resolvesToLowPowerMode(
                isSystemLowPowerModeEnabled: true,
                isOnBattery: nil
            ) == false
        )
    }

    @Test("Battery-only preference is coerced to auto when battery policy is unavailable")
    func batteryOnlyCoercionForUnsupportedPolicy() {
        #expect(
            MirageCodecLowPowerModePreference.onlyOnBattery
                .resolvedForBatteryPolicySupport(false) == .auto
        )
        #expect(
            MirageCodecLowPowerModePreference.auto
                .resolvedForBatteryPolicySupport(false) == .auto
        )
        #expect(
            MirageCodecLowPowerModePreference.on
                .resolvedForBatteryPolicySupport(false) == .on
        )
    }

    @Test("Codec low-power preference codable roundtrip")
    func codableRoundtrip() throws {
        for preference in MirageCodecLowPowerModePreference.allCases {
            let encoded = try JSONEncoder().encode(preference)
            let decoded = try JSONDecoder().decode(MirageCodecLowPowerModePreference.self, from: encoded)
            #expect(decoded == preference)
        }
    }
}
