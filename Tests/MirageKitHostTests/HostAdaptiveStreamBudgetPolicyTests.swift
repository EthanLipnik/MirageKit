//
//  HostAdaptiveStreamBudgetPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

#if os(macOS)
import CoreFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
@testable import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host Adaptive Stream Budget Policy")
struct HostAdaptiveStreamBudgetPolicyTests {
    @Test("WiFi automatic stream starts at readability floor below saturation ceiling")
    func wifiAutomaticStreamStartsAtReadabilityFloorBelowSaturationCeiling() throws {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 76_700_000,
                requestedCeilingBps: 221_500_000,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .localWiFi
            )
        )
        let expectedReadabilityFloor = try automaticReadabilityFloor(
            outputWidth: 2752,
            outputHeight: 2064,
            maxBitrateBps: 300_000_000
        )

        #expect(decision?.startupBitrateBps == expectedReadabilityFloor)
        #expect(decision?.maximumCeilingBps == 300_000_000)
        #expect(decision?.minimumBitrateFloorBps == 3_000_000)
        #expect(decision?.encoderThroughputMinimumBitrateFloorBps == 3_000_000)
    }

    @Test("VPN automatic stream honors selected client ceiling")
    func vpnAutomaticStreamHonorsSelectedClientCeiling() throws {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 64_000_000,
                requestedCeilingBps: 64_000_000,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .vpnOrOverlay,
                transportPathKind: .vpn
            )
        )
        let expectedReadabilityFloor = try automaticReadabilityFloor(
            outputWidth: 2752,
            outputHeight: 2064,
            maxBitrateBps: 64_000_000
        )

        #expect(decision?.startupBitrateBps == 64_000_000)
        #expect(decision?.maximumCeilingBps == 64_000_000)
        #expect(expectedReadabilityFloor > 8_000_000)
        #expect(decision?.minimumBitrateFloorBps == 8_000_000)
        #expect(decision?.encoderThroughputMinimumBitrateFloorBps == 8_000_000)
    }

    @Test("Optimized VPN large stream starts readable and keeps elastic recovery floor")
    func optimizedVPNLargeStreamStartsReadableAndKeepsElasticRecoveryFloor() throws {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 36_000_000,
                requestedCeilingBps: 240_000_000,
                outputWidth: 2048,
                outputHeight: 1536,
                frameRate: 30,
                mediaPathProfile: .vpnOrOverlay,
                transportPathKind: .vpn
            )
        )
        let expectedReadabilityFloor = try #require(
            MirageBitrateQualityMapper.targetBitrateBps(
                forFrameQuality: 0.75,
                width: 2048,
                height: 1536,
                frameRate: 30,
                maxBitrateBps: decision?.maximumCeilingBps ?? 1
            )
        )

        #expect(decision?.startupBitrateBps == 36_000_000)
        #expect((decision?.maximumCeilingBps ?? 0) > 70_000_000)
        #expect(expectedReadabilityFloor > 20_000_000)
        #expect(decision?.minimumBitrateFloorBps == 8_000_000)
        #expect((decision?.startupBitrateBps ?? 0) > (decision?.minimumBitrateFloorBps ?? 0))
    }

    @Test("Optimized VPN runtime quality floor stays elastic under pressure")
    func optimizedVPNRuntimeQualityFloorStaysElasticUnderPressure() async {
        let context = makeContext(
            bitrate: 36_000_000,
            frameRate: 30,
            bitrateAdaptationCeiling: 240_000_000,
            transportPathKind: .vpn,
            mediaPathProfile: .vpnOrOverlay
        )
        let outputSize = CGSize(width: 2048, height: 1536)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await context.applyRealtimeBudgetBitrate(
            8_000_000,
            ceilingBitrateBps: 36_000_000,
            encoderRateHintBps: 8_000_000,
            senderPacingBitrateBps: 8_000_000,
            minimumBitrateFloorBps: 8_000_000,
            reason: "unit-test-vpn-pressure"
        )

        let qualityFloor = await context.qualityFloor
        let keyframeQualityFloor = await context.keyframeQualityFloor
        #expect(qualityFloor < 0.50)
        #expect(keyframeQualityFloor < 0.42)
    }

    @Test("WiFi ProMotion automatic stream starts at readability floor")
    func wifiProMotionAutomaticStreamStartsAtReadabilityFloor() throws {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 120_000_000,
                requestedCeilingBps: 443_000_000,
                outputWidth: 2752,
                outputHeight: 2064,
                frameRate: 120,
                mediaPathProfile: .localWiFi
            )
        )
        let expectedReadabilityFloor = try automaticReadabilityFloor(
            outputWidth: 2752,
            outputHeight: 2064,
            frameRate: 60,
            maxBitrateBps: 300_000_000
        )
        let highRefreshReadabilityFloor = try automaticReadabilityFloor(
            outputWidth: 2752,
            outputHeight: 2064,
            frameRate: 120,
            maxBitrateBps: 300_000_000
        )

        #expect(highRefreshReadabilityFloor == expectedReadabilityFloor)
        #expect(decision?.startupBitrateBps == expectedReadabilityFloor)
        #expect((decision?.startupBitrateBps ?? 0) > 36_000_000)
        #expect(decision?.maximumCeilingBps == 300_000_000)
        #expect(decision?.minimumBitrateFloorBps == 3_000_000)
        #expect(decision?.encoderThroughputMinimumBitrateFloorBps == 3_000_000)
    }

    @Test("VPN custom stream can ramp beyond automatic ceiling")
    func vpnCustomStreamCanRampBeyondAutomaticCeiling() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 300_000_000,
                requestedCeilingBps: nil,
                enteredBitrateBps: 300_000_000,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .vpnOrOverlay,
                transportPathKind: .vpn
            )
        )

        #expect(decision?.startupBitrateBps == 153_363_456)
        #expect(decision?.maximumCeilingBps == 153_363_456)
        #expect(decision?.minimumBitrateFloorBps == 8_000_000)
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

    @Test("High-resolution proximity automatic startup protects readability floor")
    func highResolutionProximityAutomaticStartupProtectsReadabilityFloor() throws {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 120_000_000,
                requestedCeilingBps: 794_000_000,
                outputWidth: 6000,
                outputHeight: 3376,
                mediaPathProfile: .proximityWiredLike,
                transportPathKind: .wired
            )
        )
        let expectedReadabilityFloor = try #require(
            MirageBitrateQualityMapper.targetBitrateBps(
                forFrameQuality: 0.65,
                width: 6000,
                height: 3376,
                frameRate: 60,
                maxBitrateBps: 300_000_000
            )
        )

        #expect(decision?.startupBitrateBps == expectedReadabilityFloor)
        #expect((decision?.startupBitrateBps ?? 0) > 120_000_000)
        #expect(decision?.maximumCeilingBps == 300_000_000)
        #expect(decision?.minimumBitrateFloorBps == 12_000_000)
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

    @Test("Non-still clean encoder throughput raises active quality within ceiling")
    func nonStillCleanEncoderThroughputRaisesActiveQualityWithinCeiling() async {
        let context = makeContext(
            bitrate: 54_100_000,
            bitrateAdaptationCeiling: 180_000_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await context.setActiveQualityForRealtimeBudgetTest(0.42)
        await context.markSourceMovingForRealtimeBudgetTest(at: 10)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyEncoderThroughputBudgetIfNeeded(
            averageEncodeMs: 10,
            encodeAttemptFPS: 60,
            encodedFPS: 60,
            at: 10.05
        )
        let finalQuality = await context.activeQuality
        let finalConfiguredCeiling = await context.configuredQualityCeiling

        #expect((context.currentTargetBitrateBps ?? 0) > originalTarget)
        #expect(finalQuality > originalQuality)
        #expect(finalQuality <= finalConfiguredCeiling)
    }

    @Test("Still quality probe restores active quality to ceiling immediately")
    func stillQualityProbeRestoresActiveQualityToCeilingImmediately() async {
        let context = makeContext(
            bitrate: 300_000_000,
            bitrateAdaptationCeiling: 300_000_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let now: CFAbsoluteTime = 30

        await context.configureRunningForRealtimeBudgetTest()
        await context.setActiveQualityForRealtimeBudgetTest(0.42)
        await context.markSourceStillForRealtimeBudgetTest(at: now)
        await context.setLastCapturedFrameForStillQualityProbeTest(makeIdleFrame(now: now - 0.05))
        let ceiling = await min(context.configuredQualityCeiling, context.qualityCeiling)

        let scheduled = await context.scheduleStillQualityProbeIfNeeded(now: now, reason: "test")

        #expect(scheduled)
        #expect(await abs(Double(context.activeQuality - ceiling)) < 0.0001)
    }

    @Test("Per-frame encoder timing pressure cuts automatic quality before metrics window")
    func perFrameEncoderTimingPressureCutsAutomaticQualityBeforeMetricsWindow() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyPerFrameEncoderTimingPressureIfNeeded(
            VideoEncoder.EncodedFrameTiming(
                frameNumber: 12,
                encodeDurationMs: 45,
                captureToCallbackMs: 62,
                captureDirtyPercentage: 100,
                captureIsIdleFrame: false
            ),
            isKeyframe: false,
            now: 10
        )

        #expect((context.currentTargetBitrateBps ?? 0) < originalTarget)
        #expect(await context.activeQuality < originalQuality)
        #expect(await context.realtimePressureReason == HostAdaptivePFrameController.Reason.encoderLag.rawValue)
    }

    @Test("Startup local-clean encoder threshold wobble does not cut automatic quality")
    func startupLocalCleanEncoderThresholdWobbleDoesNotCutAutomaticQuality() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        await context.setStartupTransportProtectionForRealtimeBudgetTest(until: 20)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyPerFrameEncoderTimingPressureIfNeeded(
            VideoEncoder.EncodedFrameTiming(
                frameNumber: 36,
                encodeDurationMs: 18.8,
                captureToCallbackMs: 19.4,
                captureDirtyPercentage: 56.37,
                captureIsIdleFrame: false
            ),
            isKeyframe: false,
            now: 10
        )
        let finalQuality = await context.activeQuality

        #expect((context.currentTargetBitrateBps ?? 0) == originalTarget)
        #expect(abs(Double(finalQuality - originalQuality)) < 0.0001)
    }

    @Test("Still low-motion encoder threshold wobble does not cut automatic quality")
    func stillLowMotionEncoderThresholdWobbleDoesNotCutAutomaticQuality() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        await context.markSourceStillForRealtimeBudgetTest(at: 10)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyPerFrameEncoderTimingPressureIfNeeded(
            VideoEncoder.EncodedFrameTiming(
                frameNumber: 14,
                encodeDurationMs: 19.2,
                captureToCallbackMs: 21,
                captureDirtyPercentage: 0,
                captureIsIdleFrame: false
            ),
            isKeyframe: false,
            now: 10
        )
        let finalQuality = await context.activeQuality

        #expect((context.currentTargetBitrateBps ?? 0) == originalTarget)
        #expect(abs(Double(finalQuality - originalQuality)) < 0.0001)
    }

    @Test("ProMotion cadence above 60 fps does not cut automatic quality")
    func proMotionCadenceAboveSixtyDoesNotCutAutomaticQuality() async {
        let context = makeContext(
            bitrate: 120_000_000,
            frameRate: 120,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality
        let budgetFrameRate = await context.runtimeQualityBudgetFrameRate()

        #expect(budgetFrameRate == 60)

        await context.applyPerFrameEncoderTimingPressureIfNeeded(
            VideoEncoder.EncodedFrameTiming(
                frameNumber: 12,
                encodeDurationMs: 13,
                captureToCallbackMs: 15,
                captureDirtyPercentage: 2,
                captureIsIdleFrame: false
            ),
            isKeyframe: false,
            now: 10
        )
        await context.applyPreEncodeEncoderBacklogPressureIfNeeded(
            droppedFrameCount: 1,
            encoderLag: HostCaptureAdmissionPolicy.EncoderLagSnapshot(
                averageEncodeMs: 13,
                inFlightCount: 1,
                frameRate: 120
            ),
            now: 10.010
        )
        await context.applyFrameTransportBudgetFeedback(
            StreamPacketSender.FrameTransportCompletion(
                streamID: context.streamID,
                frameNumber: 20,
                isKeyframe: false,
                didSend: true,
                frameByteCount: 320_000,
                wireBytes: 320_000,
                packetCount: 267,
                queuedUnreliableDropCounts: QueuedUnreliableDropCounts(),
                dimensionToken: 0,
                encodedAt: 10.000,
                startedAt: 10.002,
                completedAt: 10.022
            ),
            now: 10.022
        )

        let finalQuality = await context.activeQuality
        #expect((context.currentTargetBitrateBps ?? 0) == originalTarget)
        #expect(abs(Double(finalQuality - originalQuality)) < 0.0001)
    }

    @Test("Severe ProMotion encoder lag still cuts automatic quality")
    func severeProMotionEncoderLagStillCutsAutomaticQuality() async {
        let context = makeContext(
            bitrate: 120_000_000,
            frameRate: 120,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyPerFrameEncoderTimingPressureIfNeeded(
            VideoEncoder.EncodedFrameTiming(
                frameNumber: 13,
                encodeDurationMs: 36,
                captureToCallbackMs: 45,
                captureDirtyPercentage: 100,
                captureIsIdleFrame: false
            ),
            isKeyframe: false,
            now: 10
        )

        #expect((context.currentTargetBitrateBps ?? 0) < originalTarget)
        #expect(await context.activeQuality < originalQuality)
        #expect(await context.realtimePressureReason == HostAdaptivePFrameController.Reason.encoderLag.rawValue)
    }

    @Test("Per-frame transport completion pressure cuts automatic quality before receiver feedback")
    func perFrameTransportCompletionPressureCutsAutomaticQualityBeforeReceiverFeedback() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .vpn,
            mediaPathProfile: .vpnOrOverlay
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyFrameTransportBudgetFeedback(
            StreamPacketSender.FrameTransportCompletion(
                streamID: context.streamID,
                frameNumber: 20,
                isKeyframe: false,
                didSend: true,
                frameByteCount: 900_000,
                wireBytes: 900_000,
                packetCount: 750,
                queuedUnreliableDropCounts: QueuedUnreliableDropCounts(),
                dimensionToken: 0,
                encodedAt: 10.000,
                startedAt: 10.010,
                completedAt: 10.090
            ),
            now: 10.090
        )

        #expect((context.currentTargetBitrateBps ?? 0) < originalTarget)
        #expect(await context.activeQuality < originalQuality)
        #expect(await context.realtimePressureReason == HostAdaptivePFrameController.Reason.transportBacklog.rawValue)
    }

    @Test("Single deadline fragment under transport threshold does not cut automatic quality")
    func singleDeadlineFragmentUnderTransportThresholdDoesNotCutAutomaticQuality() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyFrameTransportBudgetFeedback(
            StreamPacketSender.FrameTransportCompletion(
                streamID: context.streamID,
                frameNumber: 22,
                isKeyframe: false,
                didSend: false,
                frameByteCount: 56_000,
                wireBytes: 56_000,
                packetCount: 46,
                queuedUnreliableDropCounts: QueuedUnreliableDropCounts(deadlineExpired: 1),
                dimensionToken: 0,
                encodedAt: 10.000,
                startedAt: 10.0001,
                completedAt: 10.0189
            ),
            now: 10.0189
        )
        let finalQuality = await context.activeQuality

        #expect((context.currentTargetBitrateBps ?? 0) == originalTarget)
        #expect(abs(Double(finalQuality - originalQuality)) < 0.0001)
    }

    @Test("Startup pipeline jitter without encode pressure does not cut automatic quality")
    func startupPipelineJitterWithoutEncodePressureDoesNotCutAutomaticQuality() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await context.setStartupTransportProtectionForRealtimeBudgetTest(until: 20)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyPerFrameEncoderTimingPressureIfNeeded(
            VideoEncoder.EncodedFrameTiming(
                frameNumber: 4,
                encodeDurationMs: 15.2,
                captureToCallbackMs: 52.3,
                captureDirtyPercentage: 76.6,
                captureIsIdleFrame: false
            ),
            isKeyframe: false,
            now: 10
        )
        let finalQuality = await context.activeQuality

        #expect((context.currentTargetBitrateBps ?? 0) == originalTarget)
        #expect(abs(Double(finalQuality - originalQuality)) < 0.0001)
    }

    @Test("Sparse send-gap P99 without backlog does not cut automatic quality")
    func sparseSendGapP99WithoutBacklogDoesNotCutAutomaticQuality() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyQueuedUnreliableBurstPressureIfNeeded(
            queuedUnreliableTelemetry(
                sendGapP99Ms: 536.6,
                queueDwellP99Ms: 0,
                contentProcessedP99Ms: 0.3,
                outstandingMax: 3,
                pendingMax: 1,
                queuedBytesMax: 3_915,
                enqueuedCount: 23,
                completedCount: 22
            ),
            now: 10
        )
        let finalQuality = await context.activeQuality

        #expect((context.currentTargetBitrateBps ?? 0) == originalTarget)
        #expect(abs(Double(finalQuality - originalQuality)) < 0.0001)
    }

    @Test("Queue dwell P99 with live backlog is evidence-only")
    func queueDwellP99WithLiveBacklogIsEvidenceOnly() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .vpn,
            mediaPathProfile: .vpnOrOverlay
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyQueuedUnreliableBurstPressureIfNeeded(
            queuedUnreliableTelemetry(
                sendGapP99Ms: 40,
                queueDwellP99Ms: 220,
                contentProcessedP99Ms: 0.3,
                outstandingMax: 1,
                pendingMax: 4,
                queuedBytesMax: 3_915,
                enqueuedCount: 23,
                completedCount: 22
            ),
            now: 10
        )

        let finalQuality = await context.activeQuality

        #expect((context.currentTargetBitrateBps ?? 0) == originalTarget)
        #expect(abs(Double(finalQuality - originalQuality)) < 0.0001)
    }

    @Test("Local bulk queue dwell P99 observes soft backlog")
    func localBulkQueueDwellP99ObservesSoftBacklog() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 300_000_000,
            transportPathKind: .awdl,
            mediaPathProfile: .proximityWiredLike
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyQueuedUnreliableBurstPressureIfNeeded(
            queuedUnreliableTelemetry(
                sendGapP99Ms: 40,
                queueDwellP99Ms: 220,
                contentProcessedP99Ms: 0.3,
                outstandingMax: 1,
                pendingMax: 4,
                queuedBytesMax: 3_915,
                enqueuedCount: 23,
                completedCount: 22
            ),
            now: 10
        )
        let finalQuality = await context.activeQuality

        #expect((context.currentTargetBitrateBps ?? 0) == originalTarget)
        #expect(abs(Double(finalQuality - originalQuality)) < 0.0001)
    }

    @Test("Queue dwell P99 without live backlog does not cut automatic quality")
    func queueDwellP99WithoutLiveBacklogDoesNotCutAutomaticQuality() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyQueuedUnreliableBurstPressureIfNeeded(
            queuedUnreliableTelemetry(
                sendGapP99Ms: 40,
                queueDwellP99Ms: 220,
                contentProcessedP99Ms: 0.3,
                outstandingMax: 1,
                pendingMax: 1,
                queuedBytesMax: 160 * 1024,
                enqueuedCount: 23,
                completedCount: 22
            ),
            now: 10
        )
        let finalQuality = await context.activeQuality

        #expect((context.currentTargetBitrateBps ?? 0) == originalTarget)
        #expect(abs(Double(finalQuality - originalQuality)) < 0.0001)
    }

    @Test("Pre-encode encoder backlog drops cut automatic quality immediately")
    func preEncodeEncoderBacklogDropsCutAutomaticQualityImmediately() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyPreEncodeEncoderBacklogPressureIfNeeded(
            droppedFrameCount: 2,
            encoderLag: HostCaptureAdmissionPolicy.EncoderLagSnapshot(
                averageEncodeMs: 45,
                inFlightCount: 2,
                frameRate: 60
            ),
            now: 10
        )

        #expect((context.currentTargetBitrateBps ?? 0) < originalTarget)
        #expect(await context.activeQuality < originalQuality)
        #expect(await context.realtimePressureReason == HostAdaptivePFrameController.Reason.encoderLag.rawValue)
    }

    @Test("Queue-limit P-frame transport cuts automatic quality immediately")
    func queueLimitPFrameTransportCutsAutomaticQualityImmediately() async {
        let context = makeContext(
            bitrate: 120_000_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await raiseAboveReadabilityFloorForPressureTest(context)
        let originalTarget = context.currentTargetBitrateBps ?? 0
        let originalQuality = await context.activeQuality

        await context.applyFrameTransportBudgetFeedback(
            StreamPacketSender.FrameTransportCompletion(
                streamID: context.streamID,
                frameNumber: 24,
                isKeyframe: false,
                didSend: false,
                frameByteCount: 900_000,
                wireBytes: 900_000,
                packetCount: 750,
                queuedUnreliableDropCounts: QueuedUnreliableDropCounts(queueLimit: 1),
                dimensionToken: 0,
                encodedAt: 10.000,
                startedAt: 10.010,
                completedAt: 10.020
            ),
            now: 10.020
        )

        #expect((context.currentTargetBitrateBps ?? 0) < originalTarget)
        #expect(await context.activeQuality < originalQuality)
        #expect(await context.realtimePressureReason == HostAdaptivePFrameController.Reason.transportBacklog.rawValue)
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

    @Test("AWDL encoder throughput uses short backlog threshold")
    func awdlEncoderThroughputUsesShortBacklogThreshold() async {
        let context = makeContext(
            bitrate: 32_000_000,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await context.setEncodeBacklogForCatchUpTest(70)

        await context.applyEncoderThroughputBudgetIfNeeded(
            averageEncodeMs: 60,
            encodeAttemptFPS: 60,
            encodedFPS: 30,
            at: 10
        )

        #expect(context.currentFrameRate == 45)
        #expect(await !context.currentAwdlQualityReductionAllowed())
    }

    @Test("AWDL encoder throughput demotes FPS and resolution before quality")
    func awdlEncoderThroughputDemotesFPSAndResolutionBeforeQuality() async {
        let context = makeContext(
            bitrate: 32_000_000,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await context.setEncodeBacklogForCatchUpTest(1_200)

        await context.applyEncoderThroughputBudgetIfNeeded(
            averageEncodeMs: 60,
            encodeAttemptFPS: 60,
            encodedFPS: 30,
            at: 10
        )
        #expect(context.currentFrameRate == 45)
        #expect(abs((await context.streamScale) - 1.0) < 0.001)
        #expect(await !context.currentAwdlQualityReductionAllowed())

        await context.applyEncoderThroughputBudgetIfNeeded(
            averageEncodeMs: 60,
            encodeAttemptFPS: 45,
            encodedFPS: 24,
            at: 11.2
        )
        #expect(context.currentFrameRate == 30)
        #expect(abs((await context.streamScale) - 1.0) < 0.001)
        #expect(await !context.currentAwdlQualityReductionAllowed())

        await context.applyEncoderThroughputBudgetIfNeeded(
            averageEncodeMs: 70,
            encodeAttemptFPS: 30,
            encodedFPS: 18,
            at: 12.4
        )
        #expect(context.currentFrameRate == 30)
        #expect(abs((await context.streamScale) - 0.875) < 0.001)
        #expect(await !context.currentAwdlQualityReductionAllowed())

        await context.applyEncoderThroughputBudgetIfNeeded(
            averageEncodeMs: 70,
            encodeAttemptFPS: 30,
            encodedFPS: 15,
            at: 16.6
        )
        #expect(context.currentFrameRate == 30)
        #expect(abs((await context.streamScale) - 0.75) < 0.001)
        #expect(await context.currentAwdlQualityReductionAllowed())
    }

    @Test("AWDL encoded P-frame oversize steps structural ladder before quality")
    func awdlEncodedPFrameOversizeStepsStructuralLadderBeforeQuality() async {
        let context = makeContext(
            bitrate: 60_000_000,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let wireBytes = 360 * 1024

        await context.configureRunningForRealtimeBudgetTest()
        let decision = await context.evaluateEncodedFrameBudget(
            byteCount: wireBytes,
            wireBytes: wireBytes,
            packetCount: max(1, (wireBytes + 1_199) / 1_200),
            isKeyframe: false,
            encodedAt: 10
        )

        #expect(decision.admission == .send)
        #expect(decision.budgetDecision == nil)
        #expect(context.currentFrameRate == 45)
        #expect(abs((await context.streamScale) - 1.0) < 0.001)
        #expect(await !context.currentAwdlQualityReductionAllowed())
    }

    @Test("Dirty encoded frame observes oversize without clean transport pressure")
    func dirtyEncodedFrameObservesOversizeWithoutCleanTransportPressure() async {
        let context = makeContext(
            bitrate: 60_000_000,
            bitrateAdaptationCeiling: 300_000_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let wireBytes = 360 * 1024

        await context.configureRunningForRealtimeBudgetTest()
        await context.markSourceStillForRealtimeBudgetTest(at: 10)
        await context.markClientInputActiveForRealtimeBudgetTest(at: 10)
        let decision = await context.evaluateEncodedFrameBudget(
            byteCount: wireBytes,
            wireBytes: wireBytes,
            packetCount: max(1, (wireBytes + 1_199) / 1_200),
            isKeyframe: false,
            encodedAt: 10,
            timing: VideoEncoder.EncodedFrameTiming(
                frameNumber: 42,
                encodeDurationMs: 16,
                captureToCallbackMs: 18,
                captureDirtyPercentage: 100,
                captureIsIdleFrame: false
            )
        )

        #expect(decision.admission == .send)
        #expect(decision.budgetDecision == nil)
        #expect(decision.byteRatio > 1.0)
    }

    @Test("AWDL receiver P-frame timing sample steps structural ladder before quality")
    func awdlReceiverPFrameTimingSampleStepsStructuralLadderBeforeQuality() async {
        let context = makeContext(
            bitrate: 32_000_000,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let wireBytes = 160 * 1024

        await context.configureRunningForRealtimeBudgetTest()
        await context.markClientInputActiveForTimingTest()
        await context.recordReceiverPFrameCompletionForTimingTest(
            frameNumber: 42,
            wireBytes: wireBytes,
            at: 10
        )
        await context.applyReceiverMediaFeedback(
            receiverTimingFeedback(
                sequence: 1,
                frameNumber: 42,
                packetSpanMs: 12,
                completionGapMs: 120
            )
        )

        #expect(context.currentFrameRate == 45)
        #expect(abs((await context.streamScale) - 1.0) < 0.001)
        #expect(await !context.currentAwdlQualityReductionAllowed())
    }

    @Test("Missing client ceiling keeps host-owned recovery ceiling")
    func missingClientCeilingKeepsHostOwnedRecoveryCeiling() throws {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 40_000_000,
                requestedCeilingBps: nil,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .localWiFi
            )
        )
        let expectedReadabilityFloor = try automaticReadabilityFloor(
            outputWidth: 2752,
            outputHeight: 2064,
            maxBitrateBps: 300_000_000
        )

        #expect(decision?.startupBitrateBps == expectedReadabilityFloor)
        #expect(decision?.maximumCeilingBps == 300_000_000)
    }

    @Test("Stream boundary log includes quality cadence and raw policy paths")
    func streamBoundaryLogIncludesQualityCadenceAndRawPolicyPaths() async {
        let context = makeContext(
            bitrate: 120_000_000,
            frameRate: 120,
            transportPathKind: .vpn,
            mediaPathProfile: .vpnOrOverlay,
            mediaPathDiagnosticSummary:
            "hostPath=wifi/localWiFi clientPath=wifi/localWiFi clientPolicy=vpn/vpnOrOverlay resolved=vpn/vpnOrOverlay"
        )

        let log = await context.streamBoundaryLog(phase: "start", kind: "desktop", width: 3840, height: 2160)

        #expect(log.contains("event=stream_boundary phase=start"))
        #expect(log.contains("fpsCap=120"))
        #expect(log.contains("qualityRefFPS=60"))
        #expect(log.contains("hostPath=wifi/localWiFi"))
        #expect(log.contains("clientPath=wifi/localWiFi"))
        #expect(log.contains("clientPolicy=vpn/vpnOrOverlay"))
        #expect(log.contains("resolved=vpn/vpnOrOverlay"))
    }

    @Test("Stream context does not treat automatic target bitrate as manual cap")
    func streamContextDoesNotTreatAutomaticTargetBitrateAsManualCap() async throws {
        let context = makeContext(
            bitrate: 76_700_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi
        )
        let expectedReadabilityFloor = try automaticReadabilityFloor(
            outputWidth: 2752,
            outputHeight: 2064,
            maxBitrateBps: 300_000_000
        )

        await context.applyDerivedQuality(for: CGSize(width: 2752, height: 2064), logLabel: nil)

        let settings = await context.encoderSettings
        #expect(settings.bitrate == expectedReadabilityFloor)
        #expect(await context.bitrateAdaptationCeiling == 300_000_000)
        #expect(await context.realtimeRuntimeBitrateCeilingBps == expectedReadabilityFloor)
    }

    @Test("Stream context keeps oversized AWDL encoder startup inside sender pacing ceiling")
    func streamContextKeepsOversizedAwdlEncoderStartupInsideSenderPacingCeiling() async {
        let context = makeContext(
            bitrate: 220_000_000,
            bitrateAdaptationCeiling: 240_000_000,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let outputSize = CGSize(width: 5088, height: 2864)

        await context.applyDerivedQuality(for: outputSize, logLabel: nil)

        let settings = await context.encoderSettings
        #expect(settings.bitrate == 32_000_000)
        #expect(context.currentTargetBitrateBps == 32_000_000)
        #expect(await context.startupBitrate == 32_000_000)
        #expect(await context.bitrateAdaptationCeiling == 32_000_000)
        #expect(await context.realtimeRuntimeBitrateCeilingBps == 32_000_000)
        #expect(await context.realtimeSenderPacingBitrateBps == 32_000_000)
    }

    @Test("AWDL realtime sender pacing can drop below readability floor")
    func awdlRealtimeSenderPacingCanDropBelowReadabilityFloor() async {
        let context = makeContext(
            bitrate: 220_000_000,
            bitrateAdaptationCeiling: 240_000_000,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let outputSize = CGSize(width: 5088, height: 2864)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)
        await context.applyRealtimeBudgetBitrate(
            18_000_000,
            ceilingBitrateBps: 32_000_000,
            encoderRateHintBps: 18_000_000,
            senderPacingBitrateBps: 10_000_000,
            minimumBitrateFloorBps: 18_000_000,
            reason: "unit-test-awdl-pacing"
        )

        #expect(context.currentTargetBitrateBps == 18_000_000)
        #expect(await context.realtimeEncoderRateHintBps == 18_000_000)
        #expect(await context.realtimeSenderPacingBitrateBps == 10_000_000)
    }

    @Test("AWDL scale recovery keyframe keeps readable anchor quality")
    func awdlScaleRecoveryKeyframeKeepsReadableAnchorQuality() async {
        let context = makeContext(
            bitrate: 76_700_000,
            bitrateAdaptationCeiling: 221_500_000,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )
        let outputSize = CGSize(width: 2752, height: 2064)

        await context.configureRunningForRealtimeBudgetTest()
        await context.updateCaptureSizesIfNeeded(outputSize)
        await context.applyDerivedQuality(for: outputSize, logLabel: nil)

        let applied = await context.applyAwdlInteractiveScale(
            0.875,
            now: 100,
            reason: "unit-test"
        )

        #expect(applied)
        let pendingQuality = await context.pendingEmergencyKeyframeQuality
        let activeQuality = await context.activeQuality
        let qualityFloor = await context.qualityFloor
        #expect((pendingQuality ?? 0) > activeQuality * 0.65)
        #expect((pendingQuality ?? 0) >= qualityFloor)
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

    @Test("AWDL interactive display keeps safety budget when runtime adjustment is disabled")
    func awdlInteractiveDisplayKeepsSafetyBudgetWhenRuntimeAdjustmentIsDisabled() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 300_000_000,
                requestedCeilingBps: 300_000_000,
                runtimeQualityAdjustmentEnabled: false,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .awdlRadio,
                transportPathKind: .awdl
            )
        )

        #expect(decision?.startupBitrateBps == 25_560_576)
        #expect(decision?.encoderStartupBitrateBps == 25_560_576)
        #expect(decision?.maximumCeilingBps == 32_000_000)
        #expect(decision?.minimumBitrateFloorBps == 18_000_000)
        #expect(decision?.reason == "awdlInteractiveDisplay")
    }

    @Test("AWDL interactive display starts readable and protects a bitrate floor")
    func awdlInteractiveDisplayStartsReadableAndProtectsBitrateFloor() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 76_700_000,
                requestedCeilingBps: 221_500_000,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .awdlRadio
            )
        )

        #expect(decision?.startupBitrateBps == 25_560_576)
        #expect(decision?.encoderStartupBitrateBps == 25_560_576)
        #expect(decision?.maximumCeilingBps == 32_000_000)
        #expect(decision?.minimumBitrateFloorBps == 18_000_000)
        #expect(decision?.encoderThroughputMinimumBitrateFloorBps == 18_000_000)
    }

    @Test("Oversized AWDL startup keeps encoder readability budget inside transport ceiling")
    func oversizedAwdlStartupKeepsEncoderReadabilityBudgetInsideTransportCeiling() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 220_000_000,
                requestedCeilingBps: 240_000_000,
                outputWidth: 5088,
                outputHeight: 2864,
                mediaPathProfile: .awdlRadio,
                transportPathKind: .awdl
            )
        )

        #expect(decision?.startupBitrateBps == 32_000_000)
        #expect(decision?.encoderStartupBitrateBps == 32_000_000)
        #expect(decision?.maximumCeilingBps == 32_000_000)
        #expect(decision?.minimumBitrateFloorBps == 18_000_000)
    }

    @Test("AWDL interactive display ignores legacy automatic client ceiling")
    func awdlInteractiveDisplayIgnoresLegacyAutomaticClientCeiling() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 16_000_000,
                requestedCeilingBps: 24_000_000,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .awdlRadio,
                transportPathKind: .awdl
            )
        )

        #expect(decision?.startupBitrateBps == 25_560_576)
        #expect(decision?.encoderStartupBitrateBps == 25_560_576)
        #expect(decision?.maximumCeilingBps == 32_000_000)
        #expect(decision?.minimumBitrateFloorBps == 18_000_000)
    }

    @Test("AWDL interactive display honors current automatic client ceiling")
    func awdlInteractiveDisplayHonorsCurrentAutomaticClientCeiling() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 24_000_000,
                requestedCeilingBps: 32_000_000,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .awdlRadio,
                transportPathKind: .awdl
            )
        )

        #expect(decision?.startupBitrateBps == 25_560_576)
        #expect(decision?.encoderStartupBitrateBps == 25_560_576)
        #expect(decision?.maximumCeilingBps == 32_000_000)
        #expect(decision?.minimumBitrateFloorBps == 18_000_000)
    }

    @Test("AWDL interactive display protects floor from manual low caps")
    func awdlInteractiveDisplayProtectsFloorFromManualLowCaps() {
        let decision = HostAdaptiveStreamBudgetPolicy.resolve(
            request(
                requestedBitrateBps: 8_000_000,
                requestedCeilingBps: nil,
                enteredBitrateBps: 8_000_000,
                outputWidth: 2752,
                outputHeight: 2064,
                mediaPathProfile: .unknown,
                transportPathKind: .awdl
            )
        )

        #expect(decision?.startupBitrateBps == 18_000_000)
        #expect(decision?.encoderStartupBitrateBps == 18_000_000)
        #expect(decision?.maximumCeilingBps == 18_000_000)
        #expect(decision?.minimumBitrateFloorBps == 18_000_000)
    }

    @Test("Stream context resolves AWDL path with unknown profile to radio policy")
    func streamContextResolvesAwdlPathWithUnknownProfileToRadioPolicy() async {
        let context = makeContext(
            bitrate: 120_000_000,
            frameRate: 120,
            transportPathKind: .awdl,
            mediaPathProfile: .unknown
        )

        #expect(await context.mediaPathProfile == .awdlRadio)
        #expect(await context.latencyMode == .balanced)
        #expect(await context.hostBufferingPolicy == .stability)
        #expect(context.currentFrameRate == 60)
    }

    @Test("Stream context trusts resolved AWDL proximity wired profile")
    func streamContextTrustsResolvedAwdlProximityWiredProfile() async {
        let context = makeContext(
            bitrate: 120_000_000,
            frameRate: 120,
            transportPathKind: .awdl,
            mediaPathProfile: .proximityWiredLike
        )

        #expect(await context.mediaPathProfile == .proximityWiredLike)
        #expect(await context.latencyMode == .lowestLatency)
        #expect(await context.hostBufferingPolicy == .freshestFrame)
        #expect(context.currentFrameRate == 120)
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

    private func automaticReadabilityFloor(
        outputWidth: Int,
        outputHeight: Int,
        frameRate: Int = 60,
        frameQuality: Float = 0.60,
        maxBitrateBps: Int
    ) throws -> Int {
        return try #require(
            MirageBitrateQualityMapper.targetBitrateBps(
                forFrameQuality: frameQuality,
                width: outputWidth,
                height: outputHeight,
                frameRate: frameRate,
                maxBitrateBps: maxBitrateBps
            )
        )
    }

    private func makeContext(
        bitrate: Int,
        frameRate: Int = 60,
        enteredBitrate: Int? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        encoderCatchUpQualityAdjustmentEnabled: Bool = true,
        transportPathKind: MirageNetworkPathKind,
        mediaPathProfile: MirageMediaPathProfile,
        mediaPathDiagnosticSummary: String? = nil
    ) -> StreamContext {
        let config = MirageEncoderConfiguration(
            targetFrameRate: frameRate,
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
            mediaPathDiagnosticSummary: mediaPathDiagnosticSummary,
            enteredBitrate: enteredBitrate,
            bitrateAdaptationCeiling: bitrateAdaptationCeiling
        )
    }

    private func makeIdleFrame(now: CFAbsoluteTime) -> CapturedFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8,
            8,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        guard let pixelBuffer else {
            Issue.record("Failed to create CVPixelBuffer")
            fatalError("Failed to create CVPixelBuffer")
        }

        return CapturedFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: CMTime(value: 1, timescale: 60),
            duration: CMTime(value: 1, timescale: 60),
            captureTime: now,
            info: CapturedFrameInfo(
                contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
                dirtyPercentage: 0,
                isIdleFrame: true
            )
        )
    }

    private func raiseAboveReadabilityFloorForPressureTest(_ context: StreamContext) async {
        await context.applyRealtimeBudgetBitrate(
            120_000_000,
            ceilingBitrateBps: 180_000_000,
            encoderRateHintBps: 120_000_000,
            senderPacingBitrateBps: 120_000_000,
            reason: HostAdaptivePFrameController.Reason.healthy.rawValue
        )
    }

    private func receiverTimingFeedback(
        sequence: UInt64,
        frameNumber: UInt32,
        packetSpanMs: Double,
        completionGapMs: Double
    ) -> ReceiverMediaFeedbackMessage {
        ReceiverMediaFeedbackMessage(
            streamID: 3,
            sequence: sequence,
            sentAtUptime: 0,
            targetFPS: 60,
            ackRanges: [],
            pFrameTimingSamples: [
                ReceiverPFrameTimingSample(
                    frameNumber: frameNumber,
                    packetSpanMs: packetSpanMs,
                    completionGapMs: completionGapMs,
                    completionAgeAtFeedbackMs: 0,
                    firstPacketGapMs: completionGapMs
                )
            ],
            lostFrameCount: 0,
            discardedPacketCount: 0,
            jitterP95Ms: 0,
            jitterP99Ms: 0,
            queueEstimateFrames: 0,
            reassemblyBacklogFrames: 0,
            reassemblyBacklogKeyframes: 0,
            reassemblyBacklogBytes: 0,
            decodeBacklogFrames: 0,
            presentationBacklogFrames: 0,
            decodedFPS: 60,
            receivedFPS: 60,
            rendererAcceptedFPS: 60,
            rendererPresentedFPS: 60,
            recoveryState: .idle,
            playoutDelayTargetMs: 80
        )
    }

    private func queuedUnreliableTelemetry(
        sendGapP99Ms: Double,
        queueDwellP99Ms: Double,
        contentProcessedP99Ms: Double,
        outstandingMax: Int,
        pendingMax: Int,
        queuedBytesMax: Int,
        enqueuedCount: UInt64,
        completedCount: UInt64
    ) -> StreamPacketSender.TelemetrySnapshot {
        StreamPacketSender.TelemetrySnapshot(
            queuedBytes: 0,
            unstartedPFrameCount: 0,
            oldestUnstartedPFrameAgeMs: 0,
            oldestUnstartedPFrameLatenessMs: 0,
            lateReservedPFrameStreak: 0,
            sendStartDelayAverageMs: 0,
            sendStartDelayMaxMs: 0,
            sendCompletionAverageMs: 0,
            sendCompletionMaxMs: 0,
            nonKeyframeSendStartDelayMaxMs: 0,
            nonKeyframeSendCompletionMaxMs: 0,
            packetPacerSleepAverageMs: 0,
            packetPacerSleepTotalMs: 0,
            packetPacerSleepMaxMs: 0,
            packetPacerFrameMaxSleepMs: 0,
            stalePacketDrops: 0,
            senderLocalDeadlineDrops: 0,
            lateNonKeyframeSends: 0,
            generationAbortDrops: 0,
            nonKeyframeHoldDrops: 0,
            queuedUnreliableDeadlineExpiredDrops: 0,
            queuedUnreliableQueueLimitDrops: 0,
            queuedUnreliableSupersededDrops: 0,
            queuedUnreliableUnsupportedTransportDrops: 0,
            queuedUnreliableClosedDrops: 0,
            queuedUnreliablePendingPackets: pendingMax,
            queuedUnreliableOutstandingPackets: outstandingMax,
            queuedUnreliableQueuedBytes: 0,
            queuedUnreliablePendingPacketMax: pendingMax,
            queuedUnreliableOutstandingPacketMax: outstandingMax,
            queuedUnreliableQueuedBytesMax: queuedBytesMax,
            queuedUnreliableEnqueuedCount: enqueuedCount,
            queuedUnreliableSentCount: enqueuedCount,
            queuedUnreliableCompletedCount: completedCount,
            queuedUnreliableDroppedCount: 0,
            queuedUnreliableErrorCount: 0,
            queuedUnreliableQueueDwellP50Ms: 0,
            queuedUnreliableQueueDwellP95Ms: queueDwellP99Ms,
            queuedUnreliableQueueDwellP99Ms: queueDwellP99Ms,
            queuedUnreliableSendGapP50Ms: 0,
            queuedUnreliableSendGapP95Ms: sendGapP99Ms,
            queuedUnreliableSendGapP99Ms: sendGapP99Ms,
            queuedUnreliableContentProcessedP50Ms: 0,
            queuedUnreliableContentProcessedP95Ms: contentProcessedP99Ms,
            queuedUnreliableContentProcessedP99Ms: contentProcessedP99Ms
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

    func markClientInputActiveForTimingTest() {
        lastClientInputTime = CFAbsoluteTimeGetCurrent()
        lastNonIdleCapturedFrameTime = lastClientInputTime
    }

    func markClientInputActiveForRealtimeBudgetTest(at now: CFAbsoluteTime) {
        lastClientInputTime = now
    }

    func markSourceMovingForRealtimeBudgetTest(at now: CFAbsoluteTime) {
        lastNonIdleCapturedFrameTime = now
    }

    func markSourceStillForRealtimeBudgetTest(at now: CFAbsoluteTime) {
        let policy = activeFrameFreshnessPolicy
        lastClientInputTime = 0
        lastNonIdleCapturedFrameTime = now - policy.stillContentWindow - 0.01
    }

    func setActiveQualityForRealtimeBudgetTest(_ quality: Float) {
        activeQuality = quality
    }

    func setLastCapturedFrameForStillQualityProbeTest(_ frame: CapturedFrame) {
        lastCapturedFrame = frame
        lastCapturedFrameTime = frame.captureTime
    }

    func setStartupTransportProtectionForRealtimeBudgetTest(until deadline: CFAbsoluteTime) {
        startupTransportProtectionDeadline = deadline
    }

    func recordReceiverPFrameCompletionForTimingTest(
        frameNumber: UInt32,
        wireBytes: Int,
        at now: CFAbsoluteTime
    ) {
        recentFrameTransportCompletions.append(StreamPacketSender.FrameTransportCompletion(
            streamID: streamID,
            frameNumber: frameNumber,
            isKeyframe: false,
            didSend: true,
            frameByteCount: wireBytes,
            wireBytes: wireBytes,
            packetCount: max(1, (wireBytes + 1_199) / 1_200),
            queuedUnreliableDropCounts: QueuedUnreliableDropCounts(),
            dimensionToken: 0,
            encodedAt: now - 0.010,
            startedAt: now - 0.008,
            completedAt: now
        ))
    }
}
#endif
