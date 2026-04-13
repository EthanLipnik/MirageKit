//
//  DisplayRefreshRateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/5/26.
//

@testable import MirageKitClient
import Testing

@Suite("Display Refresh Rate")
struct DisplayRefreshRateTests {
    @Test("Explicit override wins over preferred refresh rate")
    func explicitOverrideWins() {
        let resolved = MirageClientService.resolvedRequestedRefreshRate(
            override: 120,
            preferredMaximumRefreshRate: 60
        )

        #expect(resolved == 120)
    }

    @Test("Preferred refresh rate is used when no override is active")
    func preferredRateIsUsedWithoutOverride() {
        let resolved = MirageClientService.resolvedRequestedRefreshRate(
            override: nil,
            preferredMaximumRefreshRate: 90
        )

        #expect(resolved == 90)
    }

    @Test("Override preserves 90 fps")
    func overridePreservesNinetyFPS() {
        let resolved = MirageClientService.resolvedRequestedRefreshRate(
            override: 90,
            preferredMaximumRefreshRate: 60
        )

        #expect(resolved == 90)
    }

    @Test("Render preferences map stored frame-rate presets")
    func renderPreferencesResolveStoredPreset() {
        #expect(MirageRenderPreferences.preferredMaximumRefreshRate(frameratePresetRawValue: "90fps") == 90)
        #expect(MirageRenderPreferences.preferredMaximumRefreshRate(frameratePresetRawValue: "120fps") == 120)
        #expect(MirageRenderPreferences.preferredMaximumRefreshRate(frameratePresetRawValue: nil) == 60)
    }
}
