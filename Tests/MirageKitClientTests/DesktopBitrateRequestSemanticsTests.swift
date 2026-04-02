//
//  DesktopBitrateRequestSemanticsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//

@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Desktop Bitrate Request Semantics")
struct DesktopBitrateRequestSemanticsTests {
    @Test("Entered desktop bitrate resolves to a single geometry-scaled effective target")
    func enteredDesktopBitrateResolvesToScaledEffectiveTarget() {
        let semantics = MirageDesktopBitrateRequestSemantics.resolve(
            enteredBitrateBps: 300_000_000,
            requestedTargetBitrateBps: 300_000_000,
            bitrateAdaptationCeilingBps: 300_000_000,
            displayResolution: CGSize(width: 3008, height: 1692)
        )

        #expect(semantics.enteredBitrateBps == 300_000_000)
        #expect(semantics.requestedTargetBitrateBps == 414_187_500)
        #expect(semantics.bitrateAdaptationCeilingBps == 414_187_500)
        #expect(abs(semantics.geometryScaleFactor - 1.380_625) < 0.000_001)
    }

    @Test("Already-effective bitrate targets are not geometry-scaled again")
    func effectiveTargetsAreNotGeometryScaledAgain() {
        let semantics = MirageDesktopBitrateRequestSemantics.resolve(
            enteredBitrateBps: nil,
            requestedTargetBitrateBps: 414_187_500,
            bitrateAdaptationCeilingBps: 488_600_000,
            displayResolution: CGSize(width: 3008, height: 1692)
        )

        #expect(semantics.enteredBitrateBps == nil)
        #expect(semantics.requestedTargetBitrateBps == 414_187_500)
        #expect(semantics.bitrateAdaptationCeilingBps == 488_600_000)
        #expect(abs(semantics.geometryScaleFactor - 1.380_625) < 0.000_001)
    }
}
