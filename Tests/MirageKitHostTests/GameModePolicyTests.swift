//
//  GameModePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/24/26.
//
//  Coverage for game-mode host policy baselines and staged overrides.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Game Mode Policy")
struct GameModePolicyTests {
    @Test("Baseline applies full game-mode host override")
    func baselineOverrides() async {
        let context = makeContext(
            targetFrameRate: 120,
            bitDepth: .tenBit,
            bitrate: 500_000_000,
            captureQueueDepth: 8,
            latencyMode: .smoothest,
            runtimeQualityAdjustmentEnabled: false,
            lowLatencyBoostEnabled: false,
            performanceMode: .game
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.performanceMode == .game)
        #expect(settings.latencyMode == .lowestLatency)
        #expect(settings.runtimeQualityAdjustmentEnabled)
        #expect(settings.lowLatencyHighResolutionCompressionBoostEnabled)
        #expect(settings.capturePressureProfile == .tuned)
        #expect(settings.captureQueueDepth == nil)
        #expect(settings.keyFrameInterval == StreamContext.gameModeBaselineKeyframeIntervalFrames)
        #expect(settings.bitDepth == .tenBit)
        #expect((settings.bitrate ?? 0) <= StreamContext.gameModeBaselineBitrateCapBps)
        #expect(await context.getTargetFrameRate() == 120)
    }

    @Test("Sustained dual-deficit windows advance staged game-mode overrides")
    func stagedDeficitTransitions() async {
        let context = makeContext(
            targetFrameRate: 120,
            bitDepth: .tenBit,
            bitrate: 300_000_000,
            captureQueueDepth: 6,
            latencyMode: .auto,
            runtimeQualityAdjustmentEnabled: true,
            lowLatencyBoostEnabled: true,
            performanceMode: .game
        )

        var now: CFAbsoluteTime = 10

        await applyDeficitWindows(
            count: 3,
            encodedFPS: 100,
            averageEncodeMs: 12,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .stage1FrameRate60)
        #expect(await context.getTargetFrameRate() == 60)

        await applyDeficitWindows(
            count: 3,
            encodedFPS: 45,
            averageEncodeMs: 20,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .stage2EightBit)
        #expect((await context.getEncoderSettings()).bitDepth == .eightBit)

        await applyDeficitWindows(
            count: 3,
            encodedFPS: 40,
            averageEncodeMs: 22,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .stage3Emergency)
        #expect((await context.getEncoderSettings()).bitrate ?? 0 <= StreamContext.gameModeEmergencyBitrateCapBps)
    }

    @Test("Stage transitions no-op when already at forced targets")
    func stageNoOpWhenAlreadyForced() async {
        let context = makeContext(
            targetFrameRate: 60,
            bitDepth: .eightBit,
            bitrate: 150_000_000,
            captureQueueDepth: 4,
            latencyMode: .auto,
            runtimeQualityAdjustmentEnabled: true,
            lowLatencyBoostEnabled: true,
            performanceMode: .game
        )

        var now: CFAbsoluteTime = 10
        await applyDeficitWindows(
            count: 3,
            encodedFPS: 40,
            averageEncodeMs: 20,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .stage1FrameRate60)
        #expect(await context.getTargetFrameRate() == 60)

        await applyDeficitWindows(
            count: 3,
            encodedFPS: 40,
            averageEncodeMs: 20,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .stage2EightBit)
        #expect((await context.getEncoderSettings()).bitDepth == .eightBit)
    }

    @Test("No in-stream restoration after game-mode fallback stages")
    func noInStreamRestoration() async {
        let context = makeContext(
            targetFrameRate: 120,
            bitDepth: .tenBit,
            bitrate: 260_000_000,
            captureQueueDepth: 6,
            latencyMode: .auto,
            runtimeQualityAdjustmentEnabled: true,
            lowLatencyBoostEnabled: true,
            performanceMode: .game
        )

        var now: CFAbsoluteTime = 10
        await applyDeficitWindows(
            count: 9,
            encodedFPS: 40,
            averageEncodeMs: 22,
            context: context,
            now: &now
        )

        let stagedSnapshot = await context.getEncoderSettings()
        let stagedFrameRate = await context.getTargetFrameRate()
        #expect(await context.getGameModeStage() == .stage3Emergency)

        await applyHealthyWindows(
            count: 5,
            encodedFPS: 60,
            averageEncodeMs: 8,
            context: context,
            now: &now
        )

        let recoveredSnapshot = await context.getEncoderSettings()
        let recoveredFrameRate = await context.getTargetFrameRate()
        #expect(await context.getGameModeStage() == .stage3Emergency)
        #expect(recoveredSnapshot.bitDepth == stagedSnapshot.bitDepth)
        #expect(recoveredSnapshot.bitrate == stagedSnapshot.bitrate)
        #expect(recoveredFrameRate == stagedFrameRate)
    }

    @Test("Standard mode preserves requested runtime behavior")
    func standardModePreservesInputs() async {
        let context = makeContext(
            targetFrameRate: 120,
            bitDepth: .tenBit,
            bitrate: 300_000_000,
            captureQueueDepth: 7,
            latencyMode: .smoothest,
            runtimeQualityAdjustmentEnabled: false,
            lowLatencyBoostEnabled: false,
            performanceMode: .standard
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.performanceMode == .standard)
        #expect(settings.latencyMode == .smoothest)
        #expect(settings.capturePressureProfile == .baseline)
        #expect(!settings.runtimeQualityAdjustmentEnabled)
        #expect(!settings.lowLatencyHighResolutionCompressionBoostEnabled)
        #expect(settings.captureQueueDepth == 7)
        #expect(settings.keyFrameInterval == 1_800)
        #expect(settings.bitrate == 300_000_000)
    }

    @Test("Missing performance mode uses standard defaults")
    func missingPerformanceModeDefaultsToStandard() async {
        let config = MirageEncoderConfiguration(targetFrameRate: 60)
        let context = StreamContext(
            streamID: 99,
            windowID: 0,
            encoderConfig: config
        )

        let settings = await context.getEncoderSettings()
        #expect(settings.performanceMode == .standard)
        #expect(settings.latencyMode == .auto)
    }

    private func makeContext(
        targetFrameRate: Int,
        bitDepth: MirageVideoBitDepth,
        bitrate: Int,
        captureQueueDepth: Int,
        latencyMode: MirageStreamLatencyMode,
        runtimeQualityAdjustmentEnabled: Bool,
        lowLatencyBoostEnabled: Bool,
        performanceMode: MirageStreamPerformanceMode
    ) -> StreamContext {
        let config = MirageEncoderConfiguration(
            targetFrameRate: targetFrameRate,
            keyFrameInterval: 1_800,
            bitDepth: bitDepth,
            captureQueueDepth: captureQueueDepth,
            bitrate: bitrate
        )

        return StreamContext(
            streamID: 42,
            windowID: 0,
            encoderConfig: config,
            runtimeQualityAdjustmentEnabled: runtimeQualityAdjustmentEnabled,
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyBoostEnabled,
            capturePressureProfile: .baseline,
            latencyMode: latencyMode,
            performanceMode: performanceMode
        )
    }

    private func applyDeficitWindows(
        count: Int,
        encodedFPS: Double,
        averageEncodeMs: Double,
        context: StreamContext,
        now: inout CFAbsoluteTime
    ) async {
        for _ in 0 ..< count {
            now += 2.1
            await context.evaluateGameModeDeficitWindowIfNeeded(
                encodedFPS: encodedFPS,
                averageEncodeMs: averageEncodeMs,
                at: now
            )
        }
    }

    private func applyHealthyWindows(
        count: Int,
        encodedFPS: Double,
        averageEncodeMs: Double,
        context: StreamContext,
        now: inout CFAbsoluteTime
    ) async {
        for _ in 0 ..< count {
            now += 2.1
            await context.evaluateGameModeDeficitWindowIfNeeded(
                encodedFPS: encodedFPS,
                averageEncodeMs: averageEncodeMs,
                at: now
            )
        }
    }
}
#endif
