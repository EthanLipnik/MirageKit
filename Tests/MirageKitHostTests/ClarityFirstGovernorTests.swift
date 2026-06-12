//
//  ClarityFirstGovernorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/12/26.
//

#if os(macOS)
import CoreFoundation
import CoreGraphics
import Foundation
@testable import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Clarity-First Governor")
struct ClarityFirstGovernorTests {
    // MARK: - Size-aware send deadlines

    private func evaluateFrame(
        controller: inout HostAdaptivePFrameController,
        wireBytes: Int,
        currentQuality: Float = 0.75,
        queuedBytesAhead: Int = 0,
        startupProtectionActive: Bool = false,
        mediaPathProfile: MirageMediaPathProfile = .vpnOrOverlay,
        now: CFAbsoluteTime = 10
    ) -> HostEncodedFrameAdmissionDecision {
        controller.evaluateEncodedFrame(
            byteCount: wireBytes,
            wireBytes: wireBytes,
            packetCount: max(1, wireBytes / 1_200),
            isKeyframe: false,
            receiverHealthy: true,
            senderHealthy: true,
            inputActive: true,
            sourceStill: false,
            currentBitrateBps: 60_000_000,
            requestedTargetBitrateBps: 60_000_000,
            startupCeilingBps: 153_000_000,
            minimumBitrateFloorBps: 8_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: currentQuality,
            qualityFloor: 0.42,
            steadyQualityCeiling: 0.90,
            latencyMode: .lowestLatency,
            mediaPathProfile: mediaPathProfile,
            queuedBytesAhead: queuedBytesAhead,
            startupProtectionActive: startupProtectionActive,
            now: now
        )
    }

    @Test("Large high-quality P-frames get deadlines covering their wire time")
    func largeHighQualityPFramesGetDeadlinesCoveringWireTime() {
        var controller = HostAdaptivePFrameController()
        // 300 KB at the 60 Mbps default capacity model is ~40 ms of wire time.
        // The legacy deadline (one 16.7 ms frame interval at quality ≥ 0.60) would
        // kill the frame mid-send and break the dependency chain.
        let decision = evaluateFrame(
            controller: &controller,
            wireBytes: 300_000,
            currentQuality: 0.75
        )
        #expect(decision.sendDeadline - 10 >= 0.045)
        #expect(decision.sendDeadline - 10 <= 0.081)
    }

    @Test("Queued bytes ahead extend the deadline up to the latency cap")
    func queuedBytesAheadExtendDeadlineUpToLatencyCap() {
        var controller = HostAdaptivePFrameController()
        let decision = evaluateFrame(
            controller: &controller,
            wireBytes: 300_000,
            queuedBytesAhead: 400_000
        )
        // (300k + 400k) bytes at ~7.5 KB/ms ≈ 93 ms × headroom — capped at the
        // lowestLatency 80 ms budget.
        #expect(abs((decision.sendDeadline - 10) - 0.080) < 0.002)
    }

    @Test("Startup transport protection grants the full latency budget")
    func startupTransportProtectionGrantsFullLatencyBudget() {
        var controller = HostAdaptivePFrameController()
        // Tiny frame, but datagram-registration latency is unmodeled: without the
        // grace every stream's first P-frame dies behind the startup keyframe.
        let decision = evaluateFrame(
            controller: &controller,
            wireBytes: 5_000,
            startupProtectionActive: true
        )
        #expect(abs((decision.sendDeadline - 10) - 0.080) < 0.002)
    }

    @Test("AWDL deadlines are unchanged by the size-aware floor")
    func awdlDeadlinesAreUnchangedBySizeAwareFloor() {
        var controller = HostAdaptivePFrameController()
        let decision = evaluateFrame(
            controller: &controller,
            wireBytes: 300_000,
            mediaPathProfile: .awdlRadio
        )
        // AWDL keeps its own playout-based hard deadlines; the base deadline
        // stays at one frame interval.
        #expect(decision.sendDeadline - 10 <= 1.0 / 60.0 + 0.001)
    }

    // MARK: - Clarity floors

    @Test("Automatic non-AWDL streams hold a readable quality floor")
    func automaticNonAwdlStreamsHoldReadableQualityFloor() async {
        let context = makeContext()
        let floor = await context.resolvedRuntimeQualityFloor(for: 0.90)
        let keyframeFloor = await context.resolvedRuntimeKeyframeQualityFloor(for: 0.90)
        #expect(floor >= 0.42)
        #expect(keyframeFloor >= 0.38)
    }

    @Test("Manual quality and AWDL floors are unchanged")
    func manualQualityAndAwdlFloorsAreUnchanged() async {
        let manualContext = makeContext(runtimeQualityAdjustmentEnabled: false)
        let manualFloor = await manualContext.resolvedRuntimeQualityFloor(for: 0.90)
        #expect(manualFloor < 0.42)

        let awdlContext = makeContext(mediaPathProfile: .awdlRadio)
        let awdlFloor = await awdlContext.resolvedRuntimeQualityFloor(for: 0.90)
        #expect(awdlFloor < 0.42)
    }

    // MARK: - Dynamic cadence ladder

    @Test("Pressure at the clarity floor demotes frame rate before quality")
    func pressureAtClarityFloorDemotesFrameRateBeforeQuality() async {
        let context = makeContext()
        await context.configureForDynamicCadenceTest(
            pressure: .pressured,
            quality: 0.43,
            floor: 0.42
        )

        await context.applyDynamicCadenceIfNeeded(now: 10)
        #expect(await context.testCurrentFrameRate() == 45)

        // Within the demote cooldown nothing moves even under pressure.
        await context.configureForDynamicCadenceTest(
            pressure: .pressured,
            quality: 0.43,
            floor: 0.42
        )
        await context.applyDynamicCadenceIfNeeded(now: 10.5)
        #expect(await context.testCurrentFrameRate() == 45)

        // Sustained pressure keeps walking the ladder down to the minimum.
        await context.applyDynamicCadenceIfNeeded(now: 13)
        #expect(await context.testCurrentFrameRate() == 30)
        await context.configureForDynamicCadenceTest(
            pressure: .severe,
            quality: 0.43,
            floor: 0.42
        )
        await context.applyDynamicCadenceIfNeeded(now: 16)
        #expect(await context.testCurrentFrameRate() == 24)
        await context.applyDynamicCadenceIfNeeded(now: 19)
        #expect(await context.testCurrentFrameRate() == 24)
    }

    @Test("Quality above the floor blocks cadence demotion")
    func qualityAboveFloorBlocksCadenceDemotion() async {
        let context = makeContext()
        await context.configureForDynamicCadenceTest(
            pressure: .pressured,
            quality: 0.60,
            floor: 0.42
        )
        await context.applyDynamicCadenceIfNeeded(now: 10)
        #expect(await context.testCurrentFrameRate() == 60)
    }

    @Test("Recovered quality with headroom promotes cadence back toward base")
    func recoveredQualityWithHeadroomPromotesCadenceBackTowardBase() async {
        let context = makeContext()
        await context.configureForDynamicCadenceTest(
            pressure: .pressured,
            quality: 0.43,
            floor: 0.42
        )
        await context.applyDynamicCadenceIfNeeded(now: 10)
        #expect(await context.testCurrentFrameRate() == 45)

        // updateFrameRate resets transient pressure to observing; mark quality
        // recovered and let the promote cooldown elapse.
        await context.configureForDynamicCadenceTest(
            pressure: .observing,
            quality: 0.80,
            floor: 0.42
        )
        await context.applyDynamicCadenceIfNeeded(now: 16)
        #expect(await context.testCurrentFrameRate() == 60)

        // Back at base: the ladder re-anchors and nothing promotes further.
        await context.applyDynamicCadenceIfNeeded(now: 30)
        #expect(await context.testCurrentFrameRate() == 60)
    }

    @Test("AWDL and manual-quality streams never take dynamic cadence steps")
    func awdlAndManualQualityStreamsNeverTakeDynamicCadenceSteps() async {
        let awdlContext = makeContext(mediaPathProfile: .awdlRadio)
        await awdlContext.configureForDynamicCadenceTest(
            pressure: .severe,
            quality: 0.20,
            floor: 0.16
        )
        await awdlContext.applyDynamicCadenceIfNeeded(now: 10)
        #expect(await awdlContext.testCurrentFrameRate() == 60)

        let manualContext = makeContext(runtimeQualityAdjustmentEnabled: false)
        await manualContext.configureForDynamicCadenceTest(
            pressure: .severe,
            quality: 0.43,
            floor: 0.42
        )
        await manualContext.applyDynamicCadenceIfNeeded(now: 10)
        #expect(await manualContext.testCurrentFrameRate() == 60)
    }

    // MARK: - Helpers

    private func makeContext(
        frameRate: Int = 60,
        bitrate: Int = 60_000_000,
        runtimeQualityAdjustmentEnabled: Bool = true,
        mediaPathProfile: MirageMediaPathProfile? = nil
    ) -> StreamContext {
        let encoderConfig = MirageEncoderConfiguration(
            targetFrameRate: frameRate,
            keyFrameInterval: 1800,
            colorDepth: .pro,
            colorSpace: .displayP3,
            pixelFormat: .bgr10a2,
            bitrate: bitrate
        )
        return StreamContext(
            streamID: 1,
            windowID: 1,
            encoderConfig: encoderConfig,
            streamScale: 1.0,
            runtimeQualityAdjustmentEnabled: runtimeQualityAdjustmentEnabled,
            lowLatencyHighResolutionCompressionBoostEnabled: true,
            latencyMode: .lowestLatency,
            transportPathKind: .unknown,
            mediaPathProfile: mediaPathProfile
        )
    }
}

private extension StreamContext {
    func configureForDynamicCadenceTest(
        pressure: HostAdaptivePFrameController.PressureState,
        quality: Float,
        floor: Float
    ) {
        isRunning = true
        realtimePressureState = pressure
        activeQuality = quality
        qualityFloor = floor
    }

    func testCurrentFrameRate() -> Int {
        currentFrameRate
    }
}
#endif
