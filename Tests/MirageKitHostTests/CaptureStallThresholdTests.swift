//
//  CaptureStallThresholdTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/8/26.
//
//  Capture stall threshold selection coverage.
//

@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("Capture Stall Threshold")
struct CaptureStallThresholdTests {
    @Test("Display capture uses 1.5 second stall threshold")
    func displayCaptureUsesFastThreshold() {
        let resolved = CaptureStreamOutput.resolvedStallLimit(
            windowID: 0,
            configuredStallLimit: 3.5
        )

        #expect(resolved == 1.5)
    }

    @Test("Window capture keeps extended stall threshold")
    func windowCaptureKeepsExtendedThreshold() {
        let resolvedFromLow = CaptureStreamOutput.resolvedStallLimit(
            windowID: 42,
            configuredStallLimit: 1.0
        )
        let resolvedFromHigh = CaptureStreamOutput.resolvedStallLimit(
            windowID: 42,
            configuredStallLimit: 9.0
        )

        #expect(resolvedFromLow == 8.0)
        #expect(resolvedFromHigh == 9.0)
    }
}
#endif
