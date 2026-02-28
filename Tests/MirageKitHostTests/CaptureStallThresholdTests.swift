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
    @Test("Display capture bounds stall threshold to 2-4 seconds")
    func displayCaptureUsesBoundedThreshold() {
        let resolvedFromLow = CaptureStreamOutput.resolvedStallLimit(
            windowID: 0,
            configuredStallLimit: 1.0
        )
        let resolvedMid = CaptureStreamOutput.resolvedStallLimit(
            windowID: 0,
            configuredStallLimit: 2.5
        )
        let resolvedFromHigh = CaptureStreamOutput.resolvedStallLimit(
            windowID: 0,
            configuredStallLimit: 5.0
        )

        #expect(resolvedFromLow == 2.0)
        #expect(resolvedMid == 2.5)
        #expect(resolvedFromHigh == 4.0)
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

    @Test("Fallback-resume keyframe threshold scales with frame-gap tolerance")
    func fallbackResumeKeyframeThresholdScaling() {
        let highFPS = CaptureStreamOutput.fallbackResumeKeyframeThreshold(frameGapThreshold: 0.3)
        let lowFPS = CaptureStreamOutput.fallbackResumeKeyframeThreshold(frameGapThreshold: 1.5)

        #expect(highFPS == 1.0)
        #expect(abs(lowFPS - 3.75) < 0.000_1)

        #expect(
            CaptureStreamOutput.shouldRequestFallbackResumeKeyframe(
                fallbackDuration: 2.0,
                frameGapThreshold: 1.5
            ) == false
        )
        #expect(
            CaptureStreamOutput.shouldRequestFallbackResumeKeyframe(
                fallbackDuration: 4.0,
                frameGapThreshold: 1.5
            )
        )
    }
}
#endif
