//
//  HostAdaptiveStreamBudgetPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

#if os(macOS)
import CoreGraphics
@testable import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host Adaptive Stream Budget Policy")
struct HostAdaptiveStreamBudgetPolicyTests {
    @Test("WiFi automatic stream starts at conservative host probe below saturation ceiling")
    func wifiAutomaticStreamStartsAtConservativeHostProbeBelowSaturationCeiling() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 76_700_000,
                requestedCeilingBps: 221_500_000,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .localWiFi
            )
        )

        #expect(decision?.startupBitrateBps == 32_376_730)
        #expect(decision?.maximumCeilingBps == 180_000_000)
        #expect(decision?.minimumBitrateFloorBps == 3_000_000)
    }

    @Test("Custom adaptive bitrate remains the upper bound")
    func customAdaptiveBitrateRemainsUpperBound() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 140_000_000,
                requestedCeilingBps: 140_000_000,
                enteredBitrateBps: 60_000_000,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .localWiFi
            )
        )

        #expect(decision?.startupBitrateBps == 60_000_000)
        #expect(decision?.maximumCeilingBps == 60_000_000)
    }

    @Test("High-resolution custom bitrate keeps a readability floor and manual ceiling")
    func highResolutionCustomBitrateKeepsReadabilityFloorAndManualCeiling() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 300_000_000,
                requestedCeilingBps: nil,
                enteredBitrateBps: 300_000_000,
                outputWidth: 5088,
                outputHeight: 2864,
                mediaPathProfile: .proximityWiredLike,
                transportPathKind: .wired
            )
        )

        #expect(decision?.startupBitrateBps == 180_000_000)
        #expect(decision?.maximumCeilingBps == 300_000_000)
        #expect(decision?.minimumBitrateFloorBps == 180_000_000)
        #expect(decision?.encoderThroughputMinimumBitrateFloorBps == 12_000_000)
    }

    @Test("High-resolution custom bitrate can keep encoder catch-up pinned to readability floor")
    func highResolutionCustomBitrateCanKeepEncoderCatchUpPinnedToReadabilityFloor() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 300_000_000,
                requestedCeilingBps: nil,
                enteredBitrateBps: 300_000_000,
                encoderCatchUpQualityAdjustmentEnabled: false,
                outputWidth: 5088,
                outputHeight: 2864,
                mediaPathProfile: .proximityWiredLike,
                transportPathKind: .wired
            )
        )

        #expect(decision?.startupBitrateBps == 180_000_000)
        #expect(decision?.minimumBitrateFloorBps == 180_000_000)
        #expect(decision?.encoderThroughputMinimumBitrateFloorBps == 180_000_000)
    }

    @Test("High-resolution custom adaptive stream keeps elastic recovery floor")
    func highResolutionCustomAdaptiveStreamKeepsElasticRecoveryFloor() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 300_000_000,
                requestedCeilingBps: 300_000_000,
                enteredBitrateBps: 300_000_000,
                outputWidth: 5088,
                outputHeight: 2864,
                mediaPathProfile: .proximityWiredLike,
                transportPathKind: .wired
            )
        )

        #expect(decision?.startupBitrateBps == 140_000_000)
        #expect(decision?.maximumCeilingBps == 300_000_000)
        #expect(decision?.minimumBitrateFloorBps == 12_000_000)
        #expect(decision?.encoderThroughputMinimumBitrateFloorBps == 12_000_000)
    }

    @Test("Realtime budget clamps encoder hint to manual readability floor")
    func realtimeBudgetClampsEncoderHintToManualReadabilityFloor() async {
        let context = makeContext(
            bitrate: 300_000_000,
            enteredBitrate: 300_000_000,
            bitrateAdaptationCeiling: nil,
            transportPathKind: .wired,
            mediaPathProfile: .proximityWiredLike
        )
        let outputSize = CGSize(width: 5088, height: 2864)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await context.applyRealtimeBudgetBitrate(
            12_000_000,
            ceilingBitrateBps: 300_000_000,
            encoderRateHintBps: 12_000_000,
            senderPacingBitrateBps: 12_000_000,
            reason: "unit-test"
        )

        let settings = await context.encoderSettings
        #expect(settings.bitrate == 180_000_000)
        #expect(context.currentTargetBitrateBps == 180_000_000)
        #expect(await context.realtimeEncoderRateHintBps == 180_000_000)
        #expect(await context.realtimeSenderPacingBitrateBps == 180_000_000)
    }

    @Test("Encoder throughput waits for fixed custom backlog grace")
    func encoderThroughputWaitsForFixedCustomBacklogGrace() async {
        let context = makeContext(
            bitrate: 300_000_000,
            enteredBitrate: 300_000_000,
            bitrateAdaptationCeiling: nil,
            encoderCatchUpQualityAdjustmentEnabled: true,
            transportPathKind: .wired,
            mediaPathProfile: .proximityWiredLike
        )
        let outputSize = CGSize(width: 5088, height: 2864)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await context.setEncodeBacklogForCatchUpTest(500)
        await context.applyEncoderThroughputBudgetIfNeeded(
            averageEncodeMs: 33,
            encodeAttemptFPS: 20,
            encodedFPS: 20,
            at: 10
        )

        let settings = await context.encoderSettings
        #expect(settings.bitrate == 180_000_000)
        #expect(context.currentTargetBitrateBps == 180_000_000)
        #expect(await context.realtimeEncoderRateHintBps == nil)
    }

    @Test("Encoder throughput can cut below manual readability floor after backlog grace")
    func encoderThroughputCanCutBelowManualReadabilityFloorAfterBacklogGrace() async {
        let context = makeContext(
            bitrate: 300_000_000,
            enteredBitrate: 300_000_000,
            bitrateAdaptationCeiling: nil,
            encoderCatchUpQualityAdjustmentEnabled: true,
            transportPathKind: .wired,
            mediaPathProfile: .proximityWiredLike
        )
        let outputSize = CGSize(width: 5088, height: 2864)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await context.setEncodeBacklogForCatchUpTest(1_200)
        await context.applyEncoderThroughputBudgetIfNeeded(
            averageEncodeMs: 33,
            encodeAttemptFPS: 20,
            encodedFPS: 20,
            at: 10
        )

        let settings = await context.encoderSettings
        #expect((settings.bitrate ?? 0) < 180_000_000)
        #expect((context.currentTargetBitrateBps ?? 0) < 180_000_000)
        #expect(await context.realtimeEncoderRateHintBps == settings.bitrate)
    }

    @Test("Encoder throughput stays at readability floor when disabled")
    func encoderThroughputStaysAtReadabilityFloorWhenDisabled() async {
        let context = makeContext(
            bitrate: 300_000_000,
            enteredBitrate: 300_000_000,
            bitrateAdaptationCeiling: nil,
            encoderCatchUpQualityAdjustmentEnabled: false,
            transportPathKind: .wired,
            mediaPathProfile: .proximityWiredLike
        )
        let outputSize = CGSize(width: 5088, height: 2864)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await context.setEncodeBacklogForCatchUpTest(1_200)
        await context.applyEncoderThroughputBudgetIfNeeded(
            averageEncodeMs: 33,
            encodeAttemptFPS: 20,
            encodedFPS: 20,
            at: 10
        )

        let settings = await context.encoderSettings
        #expect(settings.bitrate == 180_000_000)
        #expect(context.currentTargetBitrateBps == 180_000_000)
        #expect(await context.realtimeEncoderRateHintBps == nil)
    }

    @Test("Missing client ceiling keeps host-owned recovery ceiling")
    func missingClientCeilingKeepsHostOwnedRecoveryCeiling() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 40_000_000,
                requestedCeilingBps: nil,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .localWiFi
            )
        )

        #expect(decision?.startupBitrateBps == 32_376_730)
        #expect(decision?.maximumCeilingBps == 180_000_000)
    }

    @Test("Stream context does not treat automatic target bitrate as manual cap")
    func streamContextDoesNotTreatAutomaticTargetBitrateAsManualCap() async {
        let context = makeContext(
            bitrate: 76_700_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )

        await context.applyDerivedQuality(for: CGSize(width: 2752, height: 2064), logLabel: nil)

        let settings = await context.encoderSettings
        #expect(settings.bitrate == 32_376_730)
        #expect(await context.bitrateAdaptationCeiling == 180_000_000)
        #expect(await context.realtimeRuntimeBitrateCeilingBps == 32_376_730)
    }

    @Test("Disabled runtime adjustment keeps fixed quality budget untouched")
    func disabledRuntimeAdjustmentKeepsFixedQualityBudgetUntouched() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 76_700_000,
                requestedCeilingBps: 221_500_000,
                runtimeQualityAdjustmentEnabled: false,
                mediaPathProfile: .localWiFi
            )
        )

        #expect(decision == nil)
    }

    @Test("AWDL stream keeps a conservative seed but can climb to a high ceiling")
    func awdlStreamKeepsConservativeSeedButClimbsToHighCeiling() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 76_700_000,
                requestedCeilingBps: 221_500_000,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .awdlRadio
            )
        )

        // AWDL radio is a high-capacity local link (the basis of Sidecar): a
        // capable link must be allowed to climb to high quality, not be hard
        // capped near 24 Mbps.
        #expect((decision?.maximumCeilingBps ?? 0) >= 150_000_000)
        // The seed stays conservative so a marginal radio is not force-fed bits;
        // the adaptive controller raises the bitrate only as the link proves clean.
        #expect((decision?.startupBitrateBps ?? 0) <= 24_000_000)
    }

    private func request(
        requestedBitrateBps: Int?,
        requestedCeilingBps: Int?,
        enteredBitrateBps: Int? = nil,
        runtimeQualityAdjustmentEnabled: Bool = true,
        encoderCatchUpQualityAdjustmentEnabled: Bool = true,
        outputWidth: Double = 1920,
        outputHeight: Double = 1080,
        frameRate: Int = 60,
        mediaPathProfile: MirageMediaPathProfile,
        transportPathKind: MirageNetworkPathKind = .wifi
    ) -> HostAdaptiveStreamBudgetPolicy.Request {
        HostAdaptiveStreamBudgetPolicy.Request(
            requestedBitrateBps: requestedBitrateBps,
            requestedCeilingBps: requestedCeilingBps,
            enteredBitrateBps: enteredBitrateBps,
            runtimeQualityAdjustmentEnabled: runtimeQualityAdjustmentEnabled,
            encoderCatchUpQualityAdjustmentEnabled: encoderCatchUpQualityAdjustmentEnabled,
            codec: .hevc,
            outputSize: CGSize(width: outputWidth, height: outputHeight),
            frameRate: frameRate,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
    }

    private func makeContext(
        bitrate: Int,
        enteredBitrate: Int? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        encoderCatchUpQualityAdjustmentEnabled: Bool = true,
        transportPathKind: MirageNetworkPathKind,
        mediaPathProfile: MirageMediaPathProfile
    ) -> StreamContext {
        let config = MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            colorDepth: .pro,
            bitrate: bitrate
        )
        return StreamContext(
            streamID: 3,
            windowID: 0,
            streamKind: .desktop,
            encoderConfig: config,
            runtimeQualityAdjustmentEnabled: true,
            encoderCatchUpQualityAdjustmentEnabled: encoderCatchUpQualityAdjustmentEnabled,
            latencyMode: .lowestLatency,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile,
            enteredBitrate: enteredBitrate,
            bitrateAdaptationCeiling: bitrateAdaptationCeiling
        )
    }
}

private extension StreamContext {
    func configureRunningForRealtimeBudgetTest() {
        isRunning = true
        shouldEncodeFrames = true
    }

    func setEncodeBacklogForCatchUpTest(_ milliseconds: Double) {
        latestEncodeStartCaptureAgeMs = milliseconds
        worstEncodeStartCaptureAgeMs = milliseconds
    }
}
#endif
