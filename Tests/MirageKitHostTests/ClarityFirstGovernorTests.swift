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
            minimumBitrateFloorBps: 10_000_000,
            currentFrameRate: 60,
            maxPayloadSize: 1_200,
            currentQuality: currentQuality,
            qualityFloor: 0.46,
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
        #expect(floor >= 0.46)
        #expect(keyframeFloor >= 0.38)
    }

    @Test("Manual quality and AWDL floors are unchanged")
    func manualQualityAndAwdlFloorsAreUnchanged() async {
        let manualContext = makeContext(runtimeQualityAdjustmentEnabled: false)
        let manualFloor = await manualContext.resolvedRuntimeQualityFloor(for: 0.90)
        #expect(manualFloor < 0.46)

        let awdlContext = makeContext(mediaPathProfile: .awdlRadio)
        let awdlFloor = await awdlContext.resolvedRuntimeQualityFloor(for: 0.90)
        #expect(awdlFloor < 0.46)
    }

    // MARK: - Dynamic cadence ladder

    @Test("Still transport admission pressure demotes cadence before quality floor")
    func stillTransportAdmissionPressureDemotesCadenceBeforeQualityFloor() async {
        let context = makeContext()
        await context.configureForDynamicCadenceTest(
            pressure: .observing,
            quality: 0.80,
            floor: 0.46
        )
        await context.configureSustainedTransportAdmissionPressureForTest(
            now: 10,
            sourceStill: true
        )

        await context.applySustainedTransportAdmissionPressureIfNeeded(now: 10)

        #expect(await context.testCurrentFrameRate() == 45)
    }

    @Test("Motion transport admission pressure preserves cadence above quality floor")
    func motionTransportAdmissionPressurePreservesCadenceAboveQualityFloor() async {
        let context = makeContext()
        await context.configureForDynamicCadenceTest(
            pressure: .observing,
            quality: 0.80,
            floor: 0.46
        )
        await context.configureSustainedTransportAdmissionPressureForTest(
            now: 10,
            sourceStill: false
        )

        await context.applySustainedTransportAdmissionPressureIfNeeded(now: 10)

        #expect(await context.testCurrentFrameRate() == 60)
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
        realtimePressureReason = pressure == .observing
            ? nil
            : HostAdaptivePFrameController.Reason.transportBacklog.rawValue
        activeQuality = quality
        qualityFloor = floor
        if pressure == .observing {
            transportAdmissionPressureState = HostTransportAdmissionPressureState()
            senderFrameBudgetDropHoldUntil = 0
        } else {
            transportAdmissionPressureState = HostTransportAdmissionPressureState(
                mode: pressure == .severe ? .hardThrottle : .softThrottle,
                reason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue,
                evidence: pressure == .severe ? "hard:transport-backlog" : "soft:transport-backlog",
                firstSkipTime: 1,
                lastSkipTime: 9,
                activeUntil: 10_000,
                skipBurstCount: 3,
                lastMinimumFrameIntervalMs: 33.3,
                lastStructuralStepTime: 0
            )
            senderFrameBudgetDropHoldUntil = 10_000
            lastClientInputTime = 9.9
            lastNonIdleCapturedFrameTime = 9.9
        }
    }

    func testCurrentFrameRate() -> Int {
        currentFrameRate
    }

    func configureSustainedTransportAdmissionPressureForTest(
        now: CFAbsoluteTime,
        sourceStill: Bool = false
    ) {
        transportAdmissionPressureState = HostTransportAdmissionPressureState(
            mode: .softThrottle,
            reason: HostAdaptivePFrameController.Reason.transportBacklog.rawValue,
            evidence: "soft:transport-backlog",
            firstSkipTime: now - 2.1,
            lastSkipTime: now,
            activeUntil: now + 1.0,
            skipBurstCount: 3,
            lastMinimumFrameIntervalMs: 33.3,
            lastStructuralStepTime: 0
        )
        senderFrameBudgetDropHoldUntil = now + 1.0
        if sourceStill {
            let policy = activeFrameFreshnessPolicy
            lastClientInputTime = 0
            lastNonIdleCapturedFrameTime = now - policy.stillContentWindow - 0.01
        } else {
            lastNonIdleCapturedFrameTime = now
        }
    }
}
#endif
