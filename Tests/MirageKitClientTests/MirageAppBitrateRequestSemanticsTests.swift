//
//  MirageAppBitrateRequestSemanticsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

@testable import MirageKitClient
import Testing

@Suite("App Bitrate Request Semantics")
struct MirageAppBitrateRequestSemanticsTests {
    @Test("Manual app bitrate remains atlas-wide")
    func manualAppBitrateRemainsAtlasWide() {
        let resolved = MirageAppBitrateRequestSemantics.resolve(
            enteredBitrateBps: 600_000_000,
            requestedTargetBitrateBps: 1_060_000_000,
            bitrateAdaptationCeilingBps: 600_000_000
        )

        #expect(resolved.enteredBitrateBps == 600_000_000)
        #expect(resolved.requestedTargetBitrateBps == 600_000_000)
        #expect(resolved.bitrateAdaptationCeilingBps == 600_000_000)
    }

    @Test("Automatic app bitrate keeps resolved budget")
    func automaticAppBitrateKeepsResolvedBudget() {
        let resolved = MirageAppBitrateRequestSemantics.resolve(
            enteredBitrateBps: nil,
            requestedTargetBitrateBps: 76_700_000,
            bitrateAdaptationCeilingBps: 221_500_000
        )

        #expect(resolved.enteredBitrateBps == nil)
        #expect(resolved.requestedTargetBitrateBps == 76_700_000)
        #expect(resolved.bitrateAdaptationCeilingBps == 221_500_000)
    }
}
