//
//  StandardTemporaryDegradationPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Standard Temporary Degradation Policy")
struct StandardTemporaryDegradationPolicyTests {
    @Test("Off keeps requested bitrate without startup reduction")
    func offKeepsRequestedBitrate() async {
        let context = makeContext(mode: .off)
        let settings = await context.getEncoderSettings()

        #expect(settings.bitrate == 120_000_000)
        #expect(settings.bitDepth == .tenBit)
    }

    @Test("Prioritize framerate starts at eighty five percent of target bitrate")
    func prioritizeFramerateStartsLower() async {
        let context = makeContext(mode: .prioritizeFramerate)
        let settings = await context.getEncoderSettings()

        #expect(settings.bitrate == 102_000_000)
        #expect(settings.bitDepth == .tenBit)
    }

    @Test("Prioritize visuals starts at ninety two percent of target bitrate")
    func prioritizeVisualsStartsLower() async {
        let context = makeContext(mode: .prioritizeVisuals)
        let settings = await context.getEncoderSettings()

        #expect(settings.bitrate == 110_400_000)
        #expect(settings.bitDepth == .tenBit)
    }

    @Test("Adaptive sessions start at requested bitrate and canonicalize to framerate-first relief")
    func adaptiveSessionsStartAtRequestedBitrateAndCanonicalizeMode() async {
        let context = makeContext(
            mode: .prioritizeVisuals,
            bitrateAdaptationCeiling: 120_000_000
        )
        let settings = await context.getEncoderSettings()

        #expect(settings.bitrate == 120_000_000)
        #expect(settings.temporaryDegradationMode == .prioritizeFramerate)
        #expect(settings.bitDepth == .tenBit)
    }

    @Test("Adaptive sessions ignore encode-only overload")
    func adaptiveSessionsIgnoreEncodeOnlyOverload() async {
        let context = makeContext(
            mode: .prioritizeFramerate,
            bitrateAdaptationCeiling: 120_000_000
        )

        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 24,
            queueBytes: 0,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 20,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.bitrate == 120_000_000)
        #expect(await context.getTargetFrameRate() == 60)
        #expect(settings.bitDepth == .tenBit)
    }

    @Test("Adaptive sessions relieve on real transport pressure")
    func adaptiveSessionsRelieveOnRealTransportPressure() async {
        let context = makeContext(
            mode: .prioritizeVisuals,
            bitrateAdaptationCeiling: 120_000_000
        )

        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 60,
            averageEncodeMs: 10,
            queueBytes: 4_000_000,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.temporaryDegradationMode == .prioritizeFramerate)
        #expect(settings.bitrate == 102_000_000)
        #expect(await context.getTargetFrameRate() == 60)
        #expect(settings.bitDepth == .tenBit)
    }

    @Test("Adaptive sessions do not ramp bitrate back toward the ceiling")
    func adaptiveSessionsDoNotRampBitrateBackTowardTheCeiling() async {
        let context = makeContext(
            mode: .prioritizeFramerate,
            bitrateAdaptationCeiling: 120_000_000
        )

        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 60,
            averageEncodeMs: 10,
            queueBytes: 4_000_000,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 10
        )
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 60,
            averageEncodeMs: 10,
            queueBytes: 0,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 12
        )
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 60,
            averageEncodeMs: 10,
            queueBytes: 0,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 14
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.bitrate == 102_000_000)
    }

    @Test("Stable windows still restore bitrate for legacy host-owned temporary degradation")
    func stableWindowsStillRestoreBitrateForLegacyTemporaryDegradation() async {
        let context = makeContext(
            mode: .prioritizeFramerate,
            bitDepth: .eightBit,
            bitrate: 60_000_000
        )

        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 60,
            averageEncodeMs: 10,
            queueBytes: 0,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 10
        )
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 60,
            averageEncodeMs: 10,
            queueBytes: 0,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 12
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.bitrate == 60_000_000)
        #expect(settings.bitDepth == .eightBit)
    }

    private func makeContext(
        mode: MirageTemporaryDegradationMode,
        bitDepth: MirageVideoBitDepth = .tenBit,
        bitrate: Int = 120_000_000,
        bitrateAdaptationCeiling: Int? = nil
    ) -> StreamContext {
        let config = MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            bitDepth: bitDepth,
            bitrate: bitrate
        )
        return StreamContext(
            streamID: 77,
            windowID: 0,
            streamKind: .desktop,
            encoderConfig: config,
            runtimeQualityAdjustmentEnabled: mode != .off,
            temporaryDegradationMode: mode,
            capturePressureProfile: .tuned,
            latencyMode: .lowestLatency,
            performanceMode: .standard,
            bitrateAdaptationCeiling: bitrateAdaptationCeiling
        )
    }
}
#endif
