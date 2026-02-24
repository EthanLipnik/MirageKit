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
import CoreGraphics
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
        #expect(!settings.runtimeQualityAdjustmentEnabled)
        #expect(!settings.lowLatencyHighResolutionCompressionBoostEnabled)
        #expect(settings.capturePressureProfile == .tuned)
        #expect(settings.captureQueueDepth == nil)
        #expect(settings.keyFrameInterval == StreamContext.gameModeBaselineKeyframeIntervalFrames)
        #expect(settings.bitDepth == .tenBit)
        #expect(settings.bitrate == 500_000_000)
        #expect(await context.getTargetFrameRate() == 120)
    }

    @Test("Game-mode warmup delays staged fallback evaluation")
    func warmupDelaysFallback() async {
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

        var now: CFAbsoluteTime = await context.getGameModeStreamStartTime()
        await applyDeficitWindows(
            count: 3,
            encodedFPS: 40,
            averageEncodeMs: 20,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .baseline)

        await applyDeficitWindows(
            count: 2,
            encodedFPS: 40,
            averageEncodeMs: 20,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .baseline)
    }

    @Test("Sustained dual-deficit windows keep Sunshine-compatible static game mode")
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

        var now: CFAbsoluteTime = await context.getGameModeStreamStartTime() + 10

        await applyDeficitWindows(
            count: 3,
            encodedFPS: 100,
            averageEncodeMs: 12,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .baseline)
        #expect(await context.getTargetFrameRate() == 120)

        await applyDeficitWindows(
            count: 3,
            encodedFPS: 45,
            averageEncodeMs: 20,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .baseline)
        #expect((await context.getEncoderSettings()).bitDepth == .tenBit)

        await applyDeficitWindows(
            count: 3,
            encodedFPS: 40,
            averageEncodeMs: 22,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .baseline)
        #expect((await context.getEncoderSettings()).bitrate == 300_000_000)
    }

    @Test("Game mode does not mutate scale or stage under deficits")
    func stageScaleFallbackWhenBitDepthAlreadyForced() async {
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

        var now: CFAbsoluteTime = await context.getGameModeStreamStartTime() + 10
        await applyDeficitWindows(
            count: 3,
            encodedFPS: 40,
            averageEncodeMs: 20,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .baseline)
        #expect(await context.getTargetFrameRate() == 60)

        await applyDeficitWindows(
            count: 3,
            encodedFPS: 40,
            averageEncodeMs: 20,
            context: context,
            now: &now
        )
        #expect(await context.getGameModeStage() == .baseline)
        #expect((await context.getEncoderSettings()).bitDepth == .eightBit)
        let stage2Scale = await context.getStreamScale()
        #expect(stage2Scale == 1.0)
    }

    @Test("Game-mode 60 Hz baseline keeps two frames in flight")
    func gameMode60HzInFlightPolicy() async {
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

        let policy = await context.getInFlightPolicy()
        #expect(policy.minInFlightFrames == StreamContext.gameModeLowLatencyInFlightLimit)
        #expect(policy.maxInFlightFrames == StreamContext.gameModeLowLatencyInFlightLimit)
        #expect(policy.maxInFlightFramesCap >= StreamContext.gameModeLowLatencyInFlightLimit)
        #expect(policy.frameBufferDepth >= StreamContext.gameModeLowLatencyInFlightLimit)
    }

    @Test("Game mode applies throughput quality cap for 4K60")
    func gameModeThroughputQualityCapAt4K60() async {
        let gameContext = makeContext(
            targetFrameRate: 60,
            bitDepth: .eightBit,
            bitrate: 600_000_000,
            captureQueueDepth: 4,
            latencyMode: .auto,
            runtimeQualityAdjustmentEnabled: false,
            lowLatencyBoostEnabled: false,
            performanceMode: .game
        )
        await gameContext.applyDerivedQuality(
            for: CGSize(width: 3_840, height: 2_160),
            logLabel: nil
        )
        let gameSettings = await gameContext.getEncoderSettings()

        let standardContext = makeContext(
            targetFrameRate: 60,
            bitDepth: .eightBit,
            bitrate: 600_000_000,
            captureQueueDepth: 4,
            latencyMode: .auto,
            runtimeQualityAdjustmentEnabled: false,
            lowLatencyBoostEnabled: false,
            performanceMode: .standard
        )
        await standardContext.applyDerivedQuality(
            for: CGSize(width: 3_840, height: 2_160),
            logLabel: nil
        )
        let standardSettings = await standardContext.getEncoderSettings()

        #expect(gameSettings.frameQuality <= 0.66)
        #expect(gameSettings.frameQuality < standardSettings.frameQuality)
        #expect(gameSettings.keyframeQuality <= gameSettings.frameQuality)
    }

    @Test("Healthy windows keep static game mode at baseline")
    func inStreamRestoration() async {
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

        var now: CFAbsoluteTime = await context.getGameModeStreamStartTime() + 10
        await applyDeficitWindows(
            count: 9,
            encodedFPS: 40,
            averageEncodeMs: 22,
            context: context,
            now: &now
        )

        let stagedSnapshot = await context.getEncoderSettings()
        #expect(await context.getGameModeStage() == .baseline)
        #expect(stagedSnapshot.bitDepth == .tenBit)
        #expect(stagedSnapshot.bitrate == 260_000_000)

        await applyHealthyWindows(
            count: 9,
            encodedFPS: 60,
            averageEncodeMs: 8,
            context: context,
            now: &now
        )

        let recoveredSnapshot = await context.getEncoderSettings()
        let recoveredFrameRate = await context.getTargetFrameRate()
        #expect(await context.getGameModeStage() == .baseline)
        #expect(recoveredSnapshot.bitDepth == .tenBit)
        #expect(recoveredSnapshot.bitrate == 260_000_000)
        #expect(recoveredFrameRate == 120)
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
