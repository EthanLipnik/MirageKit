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

    @Test("Prioritize framerate keeps bit depth fixed and reduces bitrate under overload")
    func prioritizeFramerateDropsBitrateOnly() async {
        let context = makeContext(mode: .prioritizeFramerate)
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 24,
            queueBytes: 0,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        let expectedBitrate = Int((Double(102_000_000) * 0.85).rounded(.down))
        #expect(settings.bitDepth == .tenBit)
        #expect(settings.bitrate == expectedBitrate)
    }

    @Test("Prioritize framerate continues bitrate relief when already at eight bit")
    func prioritizeFramerateDropsBitrateWhenAlreadyEightBit() async {
        let context = makeContext(mode: .prioritizeFramerate, bitDepth: .eightBit)
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 24,
            queueBytes: 0,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        let expectedBitrate = Int((Double(102_000_000) * 0.85).rounded(.down))
        #expect(settings.bitDepth == .eightBit)
        #expect(settings.bitrate == expectedBitrate)
    }

    @Test("Prioritize visuals reduces bitrate before dropping bit depth")
    func prioritizeVisualsDropsBitrateFirst() async {
        let context = makeContext(mode: .prioritizeVisuals)
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 24,
            queueBytes: 0,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.bitDepth == .tenBit)
        #expect(settings.bitrate == 99_360_000)
    }

    @Test("Forty FPS does not trigger temporary degradation by itself")
    func fortyFPSDoesNotTriggerReliefWithoutOtherPressure() async {
        let context = makeContext(mode: .prioritizeFramerate)
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 40,
            averageEncodeMs: 14,
            queueBytes: 0,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.bitDepth == .tenBit)
        #expect(settings.bitrate == 102_000_000)
    }

    @Test("Prioritize visuals keeps bit depth fixed after repeated severe overload")
    func prioritizeVisualsKeepsBitDepthAfterSevereOverload() async {
        let context = makeContext(mode: .prioritizeVisuals)

        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 30,
            queueBytes: 4_000_000,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 20,
            at: 10
        )
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 30,
            queueBytes: 4_000_000,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 20,
            at: 12
        )
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 30,
            queueBytes: 4_000_000,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 20,
            at: 14
        )

        let settings = await context.getEncoderSettings()
        let expectedBitrate = Int((Double(110_400_000) * 0.90 * 0.90 * 0.90).rounded(.down))
        #expect(settings.bitDepth == .tenBit)
        #expect(settings.bitrate == expectedBitrate)
    }

    @Test("Stable windows ramp bitrate back toward target")
    func stableWindowsRestoreBitrate() async {
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

    @Test("App-owned visual-priority adaptation does not ramp bitrate back toward the ceiling")
    func appOwnedVisualPriorityAdaptationDoesNotRestoreBitrate() async {
        let context = makeContext(
            mode: .prioritizeVisuals,
            bitDepth: .eightBit,
            bitrate: 60_000_000,
            bitrateAdaptationCeiling: 120_000_000
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
        #expect(settings.bitrate == 55_200_000)
        #expect(settings.bitDepth == .eightBit)
    }

    @Test("App-owned visual-priority adaptation drops frame rate before bitrate")
    func appOwnedVisualPriorityAdaptationDropsFrameRateBeforeBitrate() async {
        let context = makeContext(
            mode: .prioritizeVisuals,
            bitrate: 60_000_000,
            bitrateAdaptationCeiling: 120_000_000
        )

        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 24,
            queueBytes: 0,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        let targetFrameRate = await context.getTargetFrameRate()
        #expect(targetFrameRate == 45)
        #expect(settings.bitrate == 55_200_000)
        #expect(settings.bitDepth == .tenBit)
    }

    @Test("App-owned framerate-priority adaptation keeps frame rate fixed while dropping bitrate")
    func appOwnedFrameratePriorityAdaptationKeepsFrameRateFixed() async {
        let context = makeContext(
            mode: .prioritizeFramerate,
            bitrate: 60_000_000,
            bitrateAdaptationCeiling: 120_000_000
        )

        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 24,
            queueBytes: 0,
            backpressureDropIntervalCount: 0,
            captureDroppedFrames: 0,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        let targetFrameRate = await context.getTargetFrameRate()
        let expectedBitrate = Int((Double(60_000_000) * 0.85 * 0.85).rounded(.down))
        #expect(targetFrameRate == 60)
        #expect(settings.bitrate == expectedBitrate)
        #expect(settings.bitDepth == .tenBit)
    }

    @Test("Backpressure drops trigger framerate-first bitrate relief even after queue drains")
    func backpressureDropsTriggerRelief() async {
        let context = makeContext(mode: .prioritizeFramerate)
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 60,
            averageEncodeMs: 10,
            queueBytes: 0,
            backpressureDropIntervalCount: 3,
            captureDroppedFrames: 0,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        let expectedBitrate = Int((Double(102_000_000) * 0.85).rounded(.down))
        #expect(settings.bitDepth == .tenBit)
        #expect(settings.bitrate == expectedBitrate)
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
