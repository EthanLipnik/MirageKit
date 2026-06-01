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

    @Test("Decode-error and freeze keyframe requests bypass adaptive cooldown")
    func decodeErrorAndFreezeKeyframeRequestsBypassAdaptiveCooldown() async {
        let context = makeContext()

        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())

        let frameLossAck = await context.requestKeyframe(recoveryCause: .frameLoss)
        #expect(!frameLossAck.accepted)

        let freezeAck = await context.requestKeyframe(recoveryCause: .freezeTimeout)
        #expect(freezeAck.accepted)

        let decodeContext = makeContext()
        await decodeContext.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())

        let decodeAck = await decodeContext.requestKeyframe(recoveryCause: .decodeError)
        #expect(decodeAck.accepted)
        #expect(await decodeContext.pendingKeyframeReason == "Keyframe request")
    }

    @Test("Memory-budget keyframe requests bypass startup keyframe cooldown")
    func memoryBudgetKeyframeRequestsBypassStartupKeyframeCooldown() async {
        let context = makeContext()
        await context.recordCaptureIngress(makeIdleFrame())
        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        await context.markKeyframeInFlight(frameNumber: 0)

        let ack = await context.requestKeyframe(recoveryCause: .memoryBudget)

        #expect(ack.accepted)
        #expect(await context.pendingKeyframeReason == "Keyframe request")
        #expect(await context.pendingKeyframeRequiresReset)
        #expect(await context.pendingKeyframeRequiresFlush)
        #expect(context.epoch == 1)
        #expect(context.frameInbox.pendingCount == 1)
    }

    @Test("Running memory-budget recovery drains synthetic keyframe frame")
    func runningMemoryBudgetRecoveryDrainsSyntheticKeyframeFrame() async throws {
        let context = makeContext()
        await context.configureRunningForRepairRetryTest()
        await context.recordCaptureIngress(makeIdleFrame())

        let ack = await context.requestKeyframe(recoveryCause: .memoryBudget)

        #expect(ack.accepted)
        try await waitForSyntheticFrameDrain(on: context)
        await context.stop()
    }

    @Test("Startup-gated synthetic recovery frame drains after encoding opens")
    func startupGatedSyntheticRecoveryFrameDrainsAfterEncodingOpens() async throws {
        let context = makeContext()
        await context.recordCaptureIngress(makeIdleFrame())

        let ack = await context.requestKeyframe(recoveryCause: .memoryBudget)

        #expect(ack.accepted)
        #expect(context.frameInbox.pendingCount == 1)

        await context.configureRunningForRepairRetryTest()
        await context.scheduleProcessingIfNeeded()

        try await waitForSyntheticFrameDrain(on: context)
        await context.stop()
    }

    @Test("Receiver decode-recovery feedback schedules keyframe even when explicit request is lost")
    func receiverDecodeRecoveryFeedbackSchedulesKeyframe() async {
        let context = makeContext()

        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                recoveryState: .keyframeRecovery,
                recoveryCause: .decodeError
            )
        )

        #expect(await context.pendingKeyframeReason == "Receiver feedback keyframe recovery")
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
    }

    @Test("Receiver no-progress freeze feedback with transport evidence bypasses adaptive cooldown")
    func receiverNoProgressFreezeFeedbackWithTransportEvidenceBypassesAdaptiveCooldown() async {
        let context = makeContext()

        await context.setLastSuccessfulKeyframeSendTimeForTesting(CFAbsoluteTimeGetCurrent())
        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                recoveryState: .keyframeRecovery,
                recoveryCause: .freezeTimeout,
                reassemblerIncompleteFrameTimeouts: 1,
                reliabilityCauses: [.noProgressTimeout]
            )
        )

        #expect(await context.pendingKeyframeReason == "Receiver feedback keyframe recovery")
        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
    }

    @Test("Recovery keyframe waits for receiver acknowledgement before resuming P-frames")
    func recoveryKeyframeWaitsForReceiverAcknowledgementBeforeResumingPFrames() async throws {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()
        await context.setFrameChainStateForTesting(
            .emergencyKeyframePending(reason: "unit-test", openedAt: now),
            suppressPFrames: true
        )

        await context.handleFrameTransportCompleted(
            frameTransportCompletion(frameNumber: 44, isKeyframe: true, didSend: true, now: now)
        )

        #expect(context.suppressEncodedNonKeyframesUntilKeyframe)
        let stateAfterSend = await context.frameChainState
        guard case .emergencyKeyframePending = stateAfterSend else {
            Issue.record("Expected repair to remain pending until receiver acknowledgement")
            return
        }

        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                sequence: 2,
                recoveryState: .idle,
                recoveryCause: .none,
                ackRanges: [MediaFeedbackFrameRange(startFrame: 44, endFrame: 44)]
            )
        )

        #expect(!context.suppressEncodedNonKeyframesUntilKeyframe)
        let acceptedState = await context.frameChainState
        guard case let .postKeyframeCooling(remaining) = acceptedState else {
            Issue.record("Expected post-keyframe cooling after receiver acknowledgement")
            return
        }
        let expectedCoolingFrames = await context.postEmergencyKeyframeCleanPFrameCount
        #expect(remaining == expectedCoolingFrames)
    }

    @Test("Recovery keyframe accepts idle receiver presentation evidence")
    func recoveryKeyframeAcceptsIdleReceiverPresentationEvidence() async throws {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()
        await context.setFrameChainStateForTesting(
            .emergencyKeyframePending(reason: "unit-test", openedAt: now),
            suppressPFrames: true
        )

        await context.handleFrameTransportCompleted(
            frameTransportCompletion(frameNumber: 44, isKeyframe: true, didSend: true, now: now - 0.20)
        )

        await context.applyReceiverMediaFeedback(
            receiverRecoveryFeedback(
                sequence: 2,
                recoveryState: .idle,
                recoveryCause: .none,
                latestAcceptedFrameNumber: 44,
                latestPresentedFrameNumber: 44
            )
        )

        #expect(!context.suppressEncodedNonKeyframesUntilKeyframe)
        let acceptedState = await context.frameChainState
        guard case let .postKeyframeCooling(remaining) = acceptedState else {
            Issue.record("Expected post-keyframe cooling after receiver presentation evidence")
            return
        }
        let expectedCoolingFrames = await context.postEmergencyKeyframeCleanPFrameCount
        #expect(remaining == expectedCoolingFrames)
    }

    @Test("Emergency repair keyframe carries discontinuity reset")
    func emergencyRepairKeyframeCarriesDiscontinuityReset() async {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()

        await context.startFrameChainRepair(
            reason: "unit-test",
            firstBrokenFrame: 40,
            now: now
        )
        let queued = await context.scheduleEmergencyChainRepairKeyframe(
            reason: "unit-test",
            bypassesRecoveryCooldown: true,
            now: now
        )

        #expect(queued)
        #expect(await context.pendingKeyframeRequiresReset)
        #expect(await context.pendingKeyframeRequiresFlush)
        #expect(context.epoch == 1)
        #expect(context.dynamicFrameFlags.contains(.discontinuity))
    }

    @Test("Emergency repair keyframe arms progress retry while running")
    func emergencyRepairKeyframeArmsProgressRetryWhileRunning() async {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()
        await context.configureRunningForRepairRetryTest()
        await context.startFrameChainRepair(
            reason: "unit-test",
            firstBrokenFrame: 40,
            now: now
        )

        let queued = await context.scheduleEmergencyChainRepairKeyframe(
            reason: "unit-test",
            bypassesRecoveryCooldown: true,
            now: now
        )

        #expect(queued)
        #expect(await context.pendingKeyframeReason == "unit-test")
        #expect(await context.frameChainRepairKeyframeRetryTask != nil)

        await context.stop()
    }

    @Test("Low-latency high-res boost does not force compression at 600 Mbps")
    func lowLatencyHighResBoostRespectsHighBitrateHeadroom() async {
        let boostedContext = makeContext(
            frameRate: 60,
            bitrate: 600_000_000,
            runtimeQualityAdjustmentEnabled: false,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let baselineContext = makeContext(
            frameRate: 60,
            bitrate: 600_000_000,
            runtimeQualityAdjustmentEnabled: false,
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
            runtimeQualityAdjustmentEnabled: false,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let baselineContext = makeContext(
            frameRate: 60,
            bitrate: 25_000_000,
            runtimeQualityAdjustmentEnabled: false,
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

    @Test("Runtime bitrate raises update active quality ceiling")
    func runtimeBitrateRaisesUpdateActiveQualityCeiling() async {
        let context = makeContext(
            frameRate: 60,
            bitrate: 32_000_000,
            runtimeQualityAdjustmentEnabled: true,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let displaySize = CGSize(width: 2752, height: 2064)
        await context.updateCaptureSizesIfNeeded(displaySize)
        await context.applyDerivedQuality(for: displaySize, logLabel: nil)

        let startupQuality = await context.activeQuality
        #expect(startupQuality < 0.50)

        await context.refreshRuntimeQualityTargets(
            for: 180_000_000,
            reason: HostAdaptivePFrameController.Reason.healthy.rawValue
        )

        let raisedQuality = await context.activeQuality
        #expect(raisedQuality >= 0.70)
        #expect(raisedQuality > startupQuality + 0.20)
        #expect(await context.configuredQualityCeiling >= 0.70)
        #expect(await context.qualityCeiling >= 0.70)
    }

    @Test("Runtime recovery cuts do not collapse configured quality ceiling")
    func runtimeRecoveryCutsDoNotCollapseConfiguredQualityCeiling() async {
        let context = makeContext(
            frameRate: 60,
            bitrate: 32_000_000,
            runtimeQualityAdjustmentEnabled: true,
            latencyMode: .lowestLatency,
            lowLatencyHighResolutionCompressionBoostEnabled: true
        )
        let displaySize = CGSize(width: 2752, height: 2064)
        await context.updateCaptureSizesIfNeeded(displaySize)
        await context.applyDerivedQuality(for: displaySize, logLabel: nil)

        let startupQuality = await context.activeQuality
        let startupConfiguredCeiling = await context.configuredQualityCeiling

        await context.refreshRuntimeQualityTargets(
            for: 4_800_000,
            reason: HostAdaptivePFrameController.Reason.clientRecovery.rawValue
        )

        let cutQuality = await context.activeQuality
        let configuredCeilingAfterCut = await context.configuredQualityCeiling
        let qualityCeilingAfterCut = await context.qualityCeiling
        #expect(cutQuality < startupQuality)
        #expect(abs(configuredCeilingAfterCut - startupConfiguredCeiling) < 0.0001)
        #expect(qualityCeilingAfterCut < startupConfiguredCeiling)
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

    @Test("AWDL startup keyframes use bounded FEC block")
    func awdlStartupKeyframesUseBoundedFECBlock() async {
        let context = makeContext(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio
        )

        await context.enableStartupTransportProtection(now: 10.0)

        #expect(context.resolvedFECBlockSize(isKeyframe: true, now: 10.0) == 4)
        #expect(context.resolvedFECBlockSize(isKeyframe: false, now: 10.0) == 0)
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

    @Test("Recovery keyframe requests synthesize cached idle frame")
    func recoveryKeyframeRequestsSynthesizeCachedIdleFrame() async {
        let context = makeContext()

        await context.recordCaptureIngress(makeIdleFrame())
        _ = await context.requestKeyframe()

        #expect(context.frameInbox.pendingCount == 1)
        #expect(await context.pendingKeyframeReason == "Keyframe request")
    }

    @Test("Still quality probe synthesizes cached idle frame without SCK input")
    func stillQualityProbeSynthesizesCachedIdleFrameWithoutSCKInput() async {
        let context = makeContext()
        let now = CFAbsoluteTimeGetCurrent()

        await context.recordCaptureIngress(makeIdleFrame())
        await context.applyFrameBudgetDecision(
            HostFrameBudgetDecision(
                targetBitrateBps: 8_000_000,
                maxFrameBytes: 16 * 1024,
                maxWireBytes: 16 * 1024,
                maxPacketCount: 14,
                quality: 0.10,
                qualityCeiling: 0.10,
                keyframeQuality: 0.10,
                sendDeadline: now + 1,
                state: .pressured,
                reason: .pFrameLatency
            ),
            now: now
        )
        let scheduled = await context.scheduleStillQualityProbeIfNeeded(
            now: now + 1.0,
            reason: "test"
        )

        #expect(scheduled)
        #expect(context.frameInbox.pendingCount == 1)
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
            mediaPathProfile: .awdlRadio,
            targetBitrateBps: 24_000_000,
            maxPayloadSize: 1_200
        )
        let pFrameOverride = StreamContext.mediaPacingOverride(
            isKeyframe: false,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
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
        lowLatencyHighResolutionCompressionBoostEnabled: Bool = true,
        transportPathKind: MirageNetworkPathKind = .unknown,
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
            lowLatencyHighResolutionCompressionBoostEnabled: lowLatencyHighResolutionCompressionBoostEnabled,
            latencyMode: latencyMode,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
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

    private func waitForSyntheticFrameDrain(on context: StreamContext) async throws {
        let deadline = CFAbsoluteTimeGetCurrent() + 1.0
        while CFAbsoluteTimeGetCurrent() < deadline {
            let pendingKeyframeReason = await context.pendingKeyframeReason
            if context.frameInbox.pendingCount == 0, pendingKeyframeReason == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let pendingKeyframeReason = await context.pendingKeyframeReason ?? "nil"
        Issue.record(
            "Expected synthetic keyframe frame to drain; pending=\(context.frameInbox.pendingCount), pendingKeyframeReason=\(pendingKeyframeReason)"
        )
    }

    private func receiverRecoveryFeedback(
        sequence: UInt64 = 1,
        recoveryState: MirageMediaFeedbackRecoveryState,
        recoveryCause: MirageMediaFeedbackRecoveryCause,
        ackRanges: [MediaFeedbackFrameRange] = [],
        reassemblerIncompleteFrameTimeouts: UInt64? = nil,
        reliabilityCauses: [ReceiverMediaFeedbackReliabilityCause] = [],
        latestAcceptedFrameNumber: UInt32? = nil,
        latestPresentedFrameNumber: UInt32? = nil
    ) -> ReceiverMediaFeedbackMessage {
        ReceiverMediaFeedbackMessage(
            streamID: 1,
            sequence: sequence,
            sentAtUptime: CFAbsoluteTimeGetCurrent(),
            targetFPS: 60,
            ackRanges: ackRanges,
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
            decodedFPS: 0,
            receivedFPS: 0,
            rendererAcceptedFPS: 0,
            rendererPresentedFPS: 0,
            recoveryState: recoveryState,
            recoveryCause: recoveryCause,
            reassemblerIncompleteFrameTimeouts: reassemblerIncompleteFrameTimeouts,
            reliabilityCauses: reliabilityCauses,
            latestAcceptedFrameNumber: latestAcceptedFrameNumber,
            latestPresentedFrameNumber: latestPresentedFrameNumber
        )
    }

    private func frameTransportCompletion(
        frameNumber: UInt32,
        isKeyframe: Bool,
        didSend: Bool,
        now: CFAbsoluteTime
    ) -> StreamPacketSender.FrameTransportCompletion {
        StreamPacketSender.FrameTransportCompletion(
            streamID: 1,
            frameNumber: frameNumber,
            isKeyframe: isKeyframe,
            didSend: didSend,
            frameByteCount: isKeyframe ? 48_000 : 12_000,
            wireBytes: isKeyframe ? 50_000 : 13_000,
            packetCount: isKeyframe ? 38 : 10,
            dimensionToken: 0,
            encodedAt: now - 0.006,
            startedAt: now - 0.004,
            completedAt: now
        )
    }
}

private extension StreamContext {
    func setLastSuccessfulKeyframeSendTimeForTesting(_ time: CFAbsoluteTime) {
        lastSuccessfulKeyframeSendTime = time
    }

    func setFrameChainStateForTesting(
        _ state: HostFrameChainState,
        suppressPFrames: Bool
    ) {
        frameChainState = state
        suppressEncodedNonKeyframesUntilKeyframe = suppressPFrames
    }

    func configureRunningForRepairRetryTest() {
        isRunning = true
        shouldEncodeFrames = true
    }
}
#endif
