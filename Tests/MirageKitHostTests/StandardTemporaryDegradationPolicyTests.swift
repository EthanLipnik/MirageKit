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

    @Test("Prioritize framerate starts at seventy percent of target bitrate")
    func prioritizeFramerateStartsLower() async {
        let context = makeContext(mode: .prioritizeFramerate)
        let settings = await context.getEncoderSettings()
        #expect(settings.bitrate == 84_000_000)
        #expect(settings.bitDepth == .tenBit)
    }

    @Test("Prioritize visuals starts at eighty five percent of target bitrate")
    func prioritizeVisualsStartsLower() async {
        let context = makeContext(mode: .prioritizeVisuals)
        let settings = await context.getEncoderSettings()
        #expect(settings.bitrate == 102_000_000)
        #expect(settings.bitDepth == .tenBit)
    }

    @Test("Prioritize framerate drops to eight bit before bitrate under overload")
    func prioritizeFramerateDropsBitDepthFirst() async {
        let context = makeContext(mode: .prioritizeFramerate)
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 40,
            averageEncodeMs: 24,
            queueBytes: 0,
            captureDroppedFrames: 0,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.bitDepth == .eightBit)
        #expect(settings.bitrate == 84_000_000)
    }

    @Test("Prioritize framerate reduces bitrate after bit depth is already degraded")
    func prioritizeFramerateDropsBitrateAfterBitDepth() async {
        let context = makeContext(mode: .prioritizeFramerate, bitDepth: .eightBit)
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 40,
            averageEncodeMs: 24,
            queueBytes: 0,
            captureDroppedFrames: 0,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.bitDepth == .eightBit)
        #expect(settings.bitrate == 71_400_000)
    }

    @Test("Prioritize visuals reduces bitrate before dropping bit depth")
    func prioritizeVisualsDropsBitrateFirst() async {
        let context = makeContext(mode: .prioritizeVisuals)
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 40,
            averageEncodeMs: 24,
            queueBytes: 0,
            captureDroppedFrames: 0,
            at: 10
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.bitDepth == .tenBit)
        #expect(settings.bitrate == 91_800_000)
    }

    @Test("Prioritize visuals drops bit depth after repeated severe overload")
    func prioritizeVisualsDropsBitDepthAfterSevereOverload() async {
        let context = makeContext(mode: .prioritizeVisuals)

        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 30,
            queueBytes: 4_000_000,
            captureDroppedFrames: 20,
            at: 10
        )
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 30,
            queueBytes: 4_000_000,
            captureDroppedFrames: 20,
            at: 12
        )
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 30,
            averageEncodeMs: 30,
            queueBytes: 4_000_000,
            captureDroppedFrames: 20,
            at: 14
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.bitDepth == .eightBit)
    }

    @Test("Stable windows ramp bitrate back toward target before restoring bit depth")
    func stableWindowsRestoreBitrateBeforeBitDepth() async {
        let context = makeContext(
            mode: .prioritizeFramerate,
            bitDepth: .eightBit,
            bitrate: 60_000_000
        )

        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 60,
            averageEncodeMs: 10,
            queueBytes: 0,
            captureDroppedFrames: 0,
            at: 10
        )
        await context.evaluateStandardTemporaryDegradationIfNeeded(
            encodedFPS: 60,
            averageEncodeMs: 10,
            queueBytes: 0,
            captureDroppedFrames: 0,
            at: 12
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.bitrate == 46_200_001)
        #expect(settings.bitDepth == .eightBit)
    }

    private func makeContext(
        mode: MirageTemporaryDegradationMode,
        bitDepth: MirageVideoBitDepth = .tenBit,
        bitrate: Int = 120_000_000
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
            performanceMode: .standard
        )
    }
}
#endif
