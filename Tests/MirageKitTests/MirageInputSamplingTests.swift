//
//  MirageInputSamplingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/27/26.
//
//  Cadence and interval helpers for input sampling.
//

import Testing
@testable import MirageKit

@Suite("Input Sampling Helpers")
struct MirageInputSamplingTests {
    @Test("Clamps target frame rate into supported range")
    func clampsTargetFrameRate() {
        #expect(MirageInputSampling.clampedTargetFrameRate(10) == 30)
        #expect(MirageInputSampling.clampedTargetFrameRate(60) == 60)
        #expect(MirageInputSampling.clampedTargetFrameRate(240) == 120)
    }

    @Test("Computes output interval from target frame rate")
    func computesOutputInterval() {
        let interval60 = MirageInputSampling.outputInterval(for: 60)
        let interval120 = MirageInputSampling.outputInterval(for: 120)

        #expect(abs(interval60 - (1.0 / 60.0)) < 0.000_001)
        #expect(abs(interval120 - (1.0 / 120.0)) < 0.000_001)
    }

    @Test("Uses the slower cadence when computing synthesis threshold")
    func synthesisThresholdUsesSlowerCadence() {
        let outputInterval = 1.0 / 120.0
        let lastRawInterval = 1.0 / 60.0
        let threshold = MirageInputSampling.synthesisThreshold(
            outputInterval: outputInterval,
            lastRawDeltaInterval: lastRawInterval,
            multiplier: 1.5
        )

        #expect(abs(threshold - ((1.0 / 60.0) * 1.5)) < 0.000_001)
    }

    @Test("Extends synthesis delay for slow raw cadences")
    func synthesisThresholdExtendsForSlowCadence() {
        let outputInterval = 1.0 / 60.0
        let lastRawInterval = 1.0 / 30.0
        let threshold = MirageInputSampling.synthesisThreshold(
            outputInterval: outputInterval,
            lastRawDeltaInterval: lastRawInterval,
            multiplier: 1.5
        )

        #expect(abs(threshold - ((1.0 / 30.0) * 1.5)) < 0.000_001)
    }
}
