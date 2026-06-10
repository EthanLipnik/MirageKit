//
//  MirageDesktopBitrateRequestSemanticsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/1/26.
//

import CoreGraphics
@testable import MirageKitClient
import Testing

@Suite("Desktop Bitrate Request Semantics")
struct MirageDesktopBitrateRequestSemanticsTests {
    @Test("Manual bitrate remains literal at high resolution")
    func manualBitrateRemainsLiteralAtHighResolution() {
        let resolved = MirageDesktopBitrateRequestSemantics.resolve(
            enteredBitrateBps: 300_000_000,
            requestedTargetBitrateBps: 300_000_000,
            bitrateAdaptationCeilingBps: 300_000_000,
            displayResolution: CGSize(width: 3008, height: 1692)
        )

        #expect(resolved.enteredBitrateBps == 300_000_000)
        #expect(resolved.requestedTargetBitrateBps == 300_000_000)
        #expect(resolved.bitrateAdaptationCeilingBps == 300_000_000)
        #expect(resolved.geometryScaleFactor > 1.0)
    }

    @Test("Automatic bitrate scales target by desktop geometry and keeps ceiling")
    func automaticBitrateScalesTargetByDesktopGeometryAndKeepsCeiling() {
        let resolved = MirageDesktopBitrateRequestSemantics.resolve(
            enteredBitrateBps: nil,
            requestedTargetBitrateBps: 76_700_000,
            bitrateAdaptationCeilingBps: 221_500_000,
            displayResolution: CGSize(width: 3008, height: 1692)
        )

        #expect(resolved.enteredBitrateBps == nil)
        #expect((resolved.requestedTargetBitrateBps ?? 0) > 76_700_000)
        #expect((resolved.requestedTargetBitrateBps ?? 0) < 221_500_000)
        #expect(resolved.bitrateAdaptationCeilingBps == 221_500_000)
        #expect(resolved.geometryScaleFactor > 1.0)
    }

    @Test("Automatic bitrate geometry scaling respects ceiling")
    func automaticBitrateGeometryScalingRespectsCeiling() {
        let resolved = MirageDesktopBitrateRequestSemantics.resolve(
            enteredBitrateBps: nil,
            requestedTargetBitrateBps: 180_000_000,
            bitrateAdaptationCeilingBps: 221_500_000,
            displayResolution: CGSize(width: 6016, height: 3384)
        )

        #expect(resolved.requestedTargetBitrateBps == 221_500_000)
        #expect(resolved.bitrateAdaptationCeilingBps == 221_500_000)
        #expect(resolved.geometryScaleFactor == 2.0)
    }
}
