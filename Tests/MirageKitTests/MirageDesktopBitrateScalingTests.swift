//
//  MirageDesktopBitrateScalingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//

@testable import MirageKit
import CoreGraphics
import Testing

@Suite("Mirage Desktop Bitrate Scaling")
struct MirageDesktopBitrateScalingTests {
    @Test("Custom desktop bitrate scales once from the logical display size")
    func customDesktopBitrateScalesOnceFromLogicalDisplaySize() {
        let enteredBitrate = 300_000_000
        let displaySize = CGSize(width: 3008, height: 1692)

        let scaleFactor = MirageDesktopBitrateScaling.scaleFactor(for: displaySize)
        let effectiveBitrate = MirageDesktopBitrateScaling.effectiveBitrate(
            enteredBitrate: enteredBitrate,
            displaySize: displaySize
        )

        #expect(abs(scaleFactor - 1.380625) < 0.000_001)
        #expect(effectiveBitrate == 414_187_500)
    }

    @Test("Custom desktop bitrate scaling stays capped at two x")
    func customDesktopBitrateScalingStaysCappedAtTwoX() {
        let effectiveBitrate = MirageDesktopBitrateScaling.effectiveBitrate(
            enteredBitrate: 300_000_000,
            displaySize: CGSize(width: 6016, height: 3376)
        )

        #expect(effectiveBitrate == 600_000_000)
    }
}
