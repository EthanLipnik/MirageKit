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
    @Test("Live screen refresh rate overrides stale cached value")
    func liveRefreshRateWinsOverStaleCache() {
        let resolved = MirageClientService.resolvedScreenMaxRefreshRate(
            override: 120,
            liveScreenMax: 120,
            cachedScreenMax: 60,
            defaultScreenMax: 60
        )

        #expect(resolved == 120)
    }

    @Test("Override remains clamped to resolved screen maximum")
    func overrideClampsToResolvedScreenMaximum() {
        let resolved = MirageClientService.resolvedScreenMaxRefreshRate(
            override: 120,
            liveScreenMax: nil,
            cachedScreenMax: 60,
            defaultScreenMax: 60
        )

        #expect(resolved == 60)
    }

    @Test("Override preserves 90 fps when the display supports it")
    func overridePreservesNinetyFPS() {
        let resolved = MirageClientService.resolvedScreenMaxRefreshRate(
            override: 90,
            liveScreenMax: 120,
            cachedScreenMax: 60,
            defaultScreenMax: 60
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
