//
//  HostKeyframeRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Host keyframe recovery, FEC, and quality coverage.
//

@testable import MirageKitHost
import MirageKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing

#if os(macOS)
@Suite("Host Keyframe Recovery")
struct HostKeyframeRecoveryTests {
    @Test("Recovery keyframe requests do not escalate into host hard resets")
    func recoveryRequestsDoNotEscalateIntoHostHardResets() async throws {
        let context = makeContext()

        await context.requestKeyframeRecoveryIfPossible()
        #expect(await context.softRecoveryCount == 1)
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(await context.pendingKeyframeRequiresFlush == false)

        try await Task.sleep(for: .milliseconds(1100))
        await context.requestKeyframeRecoveryIfPossible()
        #expect(await context.softRecoveryCount == 2)
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(await context.pendingKeyframeRequiresFlush == false)

        try await Task.sleep(for: .milliseconds(1100))
        await context.requestKeyframeRecoveryIfPossible()
        #expect(await context.softRecoveryCount == 3)
        #expect(await context.pendingKeyframeRequiresReset == false)
        #expect(await context.pendingKeyframeRequiresFlush == false)
    }

    @Test("Capture-starved recovery schedules restart when no frame has arrived")
    func captureStarvedRecoveryWithNoFrames() {
        let shouldRestart = StreamContext.shouldScheduleCaptureRestartForRecovery(
            now: 10.0,
            lastCapturedFrameTime: 0,
            lastRestartTime: 0,
            stallThreshold: 0.75,
            cooldown: 1.0
        )
        #expect(shouldRestart)
    }

    @Test("Capture-starved recovery does not restart while cooldown is active")
    func captureStarvedRecoveryCooldown() {
        let shouldRestart = StreamContext.shouldScheduleCaptureRestartForRecovery(
            now: 10.0,
            lastCapturedFrameTime: 8.0,
            lastRestartTime: 9.5,
            stallThreshold: 0.75,
            cooldown: 1.0
        )
        #expect(!shouldRestart)
    }

    @Test("Capture-starved recovery waits until frame gap exceeds threshold")
    func captureStarvedRecoveryThreshold() {
        let belowThreshold = StreamContext.shouldScheduleCaptureRestartForRecovery(
            now: 10.0,
            lastCapturedFrameTime: 9.6,
            lastRestartTime: 0,
            stallThreshold: 0.75,
            cooldown: 1.0
        )
        #expect(!belowThreshold)

        let aboveThreshold = StreamContext.shouldScheduleCaptureRestartForRecovery(
            now: 10.0,
            lastCapturedFrameTime: 8.9,
            lastRestartTime: 0,
            stallThreshold: 0.75,
            cooldown: 1.0
        )
        #expect(aboveThreshold)
    }

    @Test("Low-latency high-res boost does not force compression at 600 Mbps")
    func lowLatencyHighResBoostRespectsHighBitrateHeadroom() async {
        let boostedContext = makeContext(
            frameRate: 60,
            bitrate: 600_000_000,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let baselineContext = makeContext(
            frameRate: 60,
            bitrate: 600_000_000,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: false
        )
        let fiveKSize = CGSize(width: 5120, height: 2880)
        await boostedContext.updateCaptureSizesIfNeeded(fiveKSize)
        await boostedContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)
        await baselineContext.updateCaptureSizesIfNeeded(fiveKSize)
        await baselineContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)

        let boosted = await boostedContext.activeQuality
        let baseline = await baselineContext.activeQuality
        #expect(boosted >= 0.90)
        #expect(abs(boosted - baseline) < 0.02)
    }

    @Test("Low-latency high-res boost remains aggressive at 25 Mbps")
    func lowLatencyHighResBoostStaysAggressiveWhenConstrained() async {
        let boostedContext = makeContext(
            frameRate: 60,
            bitrate: 25_000_000,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let baselineContext = makeContext(
            frameRate: 60,
            bitrate: 25_000_000,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: false
        )
        let fiveKSize = CGSize(width: 5120, height: 2880)
        await boostedContext.updateCaptureSizesIfNeeded(fiveKSize)
        await boostedContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)
        await baselineContext.updateCaptureSizesIfNeeded(fiveKSize)
        await baselineContext.applyDerivedQuality(for: fiveKSize, logLabel: nil)

        let boosted = await boostedContext.activeQuality
        let baseline = await baselineContext.activeQuality
        #expect(boosted <= 0.06)
        #expect(boosted + 0.07 < baseline)
    }

    @Test("Bitrate-capped 6K streams allow a lower runtime quality floor")
    func bitrateCappedQualityFloor() async {
        let context = makeContext(
            frameRate: 120,
            bitrate: 120_000_000
        )
        let sixKSize = CGSize(width: 6016, height: 3384)
        await context.updateCaptureSizesIfNeeded(sixKSize)
        await context.applyDerivedQuality(for: sixKSize, logLabel: nil)

        let floor = await context.qualityFloor
        #expect(floor < 0.1)
    }

    @Test("Recovery keyframe quality does not drop under queue pressure")
    func keyframeQualityDoesNotDropUnderQueuePressure() async {
        let context = makeContext(
            frameRate: 120,
            bitrate: 300_000_000
        )
        let sixKSize = CGSize(width: 6016, height: 3384)
        await context.updateCaptureSizesIfNeeded(sixKSize)
        await context.applyDerivedQuality(for: sixKSize, logLabel: nil)

        let baseline = await context.keyframeQuality
        let pressured = await context.keyframeQuality

        #expect(abs(baseline - pressured) < 0.0001)
    }

    @Test("Runtime-quality-disabled streams keep keyframe quality fixed under queue pressure")
    func keyframeQualityStaysFixedWhenRuntimeAdjustmentDisabled() async {
        let context = makeContext(
            frameRate: 120,
            bitrate: 120_000_000,
            runtimeQualityAdjustmentEnabled: false
        )
        let sixKSize = CGSize(width: 6016, height: 3384)
        await context.updateCaptureSizesIfNeeded(sixKSize)
        await context.applyDerivedQuality(for: sixKSize, logLabel: nil)

        let baseline = await context.keyframeQuality
        let pressured = await context.keyframeQuality

        #expect(abs(baseline - pressured) < 0.0001)
    }

    @Test("Recovery keyframe requests enter protected loss-mode FEC")
    func recoveryRequestsEnterProtectedLossModeFEC() async throws {
        let context = makeContext()

        await context.requestKeyframeRecoveryIfPossible()
        let softTime = CFAbsoluteTimeGetCurrent()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: softTime) == 8)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: softTime) == 16)

        try await Task.sleep(for: .milliseconds(1100))
        await context.requestKeyframeRecoveryIfPossible()
        let secondSoftTime = CFAbsoluteTimeGetCurrent()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: secondSoftTime) == 8)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: secondSoftTime) == 16)
    }

    @Test("Startup transport protection strengthens keyframe FEC")
    func startupTransportProtectionStrengthensKeyframeFEC() async {
        let context = makeContext()

        await context.enableStartupTransportProtection(now: 10.0)
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: 10.0) == 4)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: 10.0) == 0)
        #expect(StreamContext.keyframePacingOverride() == StreamPacketSender.PacingOverride(
            rateBps: 48_000_000,
            burstBytes: 16 * 1024
        ))

        await context.disableStartupTransportProtection()
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: 10.0) == 0)
    }

    @Test("Startup keyframe stays separate from recovery loss mode")
    func startupKeyframeDoesNotEnterRecoveryLossMode() async {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()

        await context.enableStartupTransportProtection(now: now)
        await context.scheduleCoalescedStartupKeyframe(
            reason: "Startup registration confirmed",
            resetFrameNumber: true
        )

        #expect(await context.pendingKeyframeReason == "Startup registration confirmed")
        #expect(context.lossModeDeadline == 0)
        #expect(context.lossModePFrameFECDeadline == 0)
        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: now) == 4)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: now) == 0)
    }

    @Test("Steady-state idle capture frames stay out of encode inbox")
    func steadyStateIdleFramesStayOutOfEncodeInbox() async {
        let context = makeContext()

        await context.recordCaptureIngress(makeIdleFrame())

        #expect(context.frameInbox.pendingCount == 0)
        #expect(await context.lastCapturedFrame?.info.isIdleFrame == true)
    }

    @Test("Recovery keyframe requests do not reopen idle capture hot path")
    func recoveryKeyframeRequestsDoNotReopenIdleCaptureHotPath() async {
        let context = makeContext()

        _ = await context.requestKeyframe()
        await context.recordCaptureIngress(makeIdleFrame())

        #expect(context.frameInbox.pendingCount == 0)
        #expect(await context.pendingKeyframeReason == "Keyframe request")
    }

    @Test("Keyframe packet pacing override caps send rate and burst budget")
    func startupPacketPacingCapsKeyframeBurstBudget() {
        let pacingOverride = StreamContext.keyframePacingOverride()
        let startupParameters = StreamPacketSender.packetPacingParameters(
            targetRateBps: 76_000_000,
            packetBytes: 1_500,
            isKeyframeBurst: true,
            totalFragments: 1_200,
            pacingOverride: pacingOverride
        )
        let steadyStateParameters = StreamPacketSender.packetPacingParameters(
            targetRateBps: 76_000_000,
            packetBytes: 1_500,
            isKeyframeBurst: true,
            totalFragments: 1_200,
            pacingOverride: nil
        )

        #expect(startupParameters != nil)
        #expect(steadyStateParameters != nil)
        #expect(Int(startupParameters?.burstBytes ?? 0) == pacingOverride.burstBytes)
        #expect((startupParameters?.bytesPerSecond ?? 0) < (steadyStateParameters?.bytesPerSecond ?? 0))
        #expect((startupParameters?.burstBytes ?? 0) <
            (startupParameters?.bytesPerSecond ?? 0) / 1_000.0 * StreamPacketSender.packetPacerBurstWindowMs)
    }

    @Test("AWDL media pacing keeps bitrate target but narrows burst budget")
    func awdlMediaPacingKeepsBitrateTargetButNarrowsBurstBudget() {
        let keyframeOverride = StreamContext.keyframePacingOverride(
            transportPathKind: .awdl,
            targetBitrateBps: 24_000_000,
            maxPayloadSize: 1_200
        )
        let pFrameOverride = StreamContext.mediaPacingOverride(
            isKeyframe: false,
            transportPathKind: .awdl,
            targetBitrateBps: 24_000_000,
            maxPayloadSize: 1_200
        )

        #expect(keyframeOverride.rateBps == 24_000_000)
        #expect(keyframeOverride.burstBytes == 4_800)
        #expect(pFrameOverride?.rateBps == 24_000_000)
        #expect(pFrameOverride?.burstBytes == 2_400)
    }

    private func makeContext(
        frameRate: Int = 60,
        bitrate: Int = 600_000_000,
        runtimeQualityAdjustmentEnabled: Bool = true,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        lowLatencyHighResolutionCompressionBoostEnabled: Bool = true
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
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyHighResolutionCompressionBoostEnabled,
            latencyMode: latencyMode
        )
    }

    private func makeIdleFrame() -> CapturedFrame {
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
            captureTime: CFAbsoluteTimeGetCurrent(),
            info: CapturedFrameInfo(
                contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
                dirtyPercentage: 0,
                isIdleFrame: true
            )
        )
    }
}
#endif
