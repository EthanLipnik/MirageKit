//
//  HostFrameFreshnessPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/31/26.
//

#if os(macOS)
import CoreFoundation
import CoreGraphics
@testable import MirageKit
@testable import MirageKitHost
import Testing
import MirageMedia
import MirageWire

@Suite("Host Frame Freshness Policy")
struct HostFrameFreshnessPolicyTests {
    @Test("Receiver quality gate allows normal pending equals one in Most Responsive")
    func receiverQualityGateAllowsNormalPendingOne() async {
        let context = makeContext(latencyMode: .lowestLatency)
        await context.configureReceiverFreshnessForTesting(
            now: 100,
            lastInputTime: 100,
            lastNonIdleCaptureTime: 100,
            presentationBacklogFrames: 1,
            latestPresentedFrameAgeMs: 50
        )

        #expect(await context.receiverFrameBudgetCanRaiseQuality(now: 100))
    }

    @Test("Receiver quality gate ignores presented age for still content")
    func receiverQualityGateIgnoresPresentedAgeForStillContent() async {
        let context = makeContext(latencyMode: .lowestLatency)
        await context.configureReceiverFreshnessForTesting(
            now: 100,
            lastInputTime: 0,
            lastNonIdleCaptureTime: 99,
            decodeBacklogFrames: 1,
            presentationBacklogFrames: 3,
            latestPresentedFrameAgeMs: 2_000
        )

        #expect(await context.receiverFrameBudgetCanRaiseQuality(now: 100))
    }

    @Test("Receiver quality gate allows small reassembly backlog for still content")
    func receiverQualityGateAllowsSmallReassemblyBacklogForStillContent() async {
        let context = makeContext(latencyMode: .lowestLatency)
        await context.configureReceiverFreshnessForTesting(
            now: 100,
            lastInputTime: 0,
            lastNonIdleCaptureTime: 99,
            reassemblyBacklogFrames: 1,
            reassemblyBacklogBytes: 128 * 1024,
            presentationBacklogFrames: 3,
            latestPresentedFrameAgeMs: 2_000
        )

        #expect(await context.receiverFrameBudgetCanRaiseQuality(now: 100))

        await context.configureReceiverFreshnessForTesting(
            now: 100,
            lastInputTime: 0,
            lastNonIdleCaptureTime: 99,
            reassemblyBacklogFrames: 3,
            reassemblyBacklogBytes: 128 * 1024,
            presentationBacklogFrames: 3,
            latestPresentedFrameAgeMs: 2_000
        )

        #expect(!(await context.receiverFrameBudgetCanRaiseQuality(now: 100)))
    }

    @Test("Receiver quality gate blocks stale presented age during input motion")
    func receiverQualityGateBlocksStalePresentedAgeDuringInputMotion() async {
        let context = makeContext(latencyMode: .lowestLatency)
        await context.configureReceiverFreshnessForTesting(
            now: 100,
            lastInputTime: 100,
            lastNonIdleCaptureTime: 100,
            presentationBacklogFrames: 1,
            latestPresentedFrameAgeMs: 200
        )

        #expect(!(await context.receiverFrameBudgetCanRaiseQuality(now: 100)))
    }

    @Test("AWDL receiver quality gate respects bounded playout age and ack lag")
    func awdlReceiverQualityGateRespectsBoundedPlayoutAgeAndAckLag() async {
        let context = makeContext(latencyMode: .balanced, mediaPathProfile: .awdlRadio)
        await context.configureReceiverFreshnessForTesting(
            now: 100,
            lastInputTime: 100,
            lastNonIdleCaptureTime: 100,
            presentationBacklogFrames: 2,
            latestPresentedFrameAgeMs: 150,
            receiverPlayoutDelayTargetMs: 120,
            receiverAckLagMs: 145,
            lastReceiverAckTime: 99.8
        )

        #expect(await context.receiverFrameBudgetCanRaiseQuality(now: 100))

        await context.configureReceiverFreshnessForTesting(
            now: 100,
            lastInputTime: 100,
            lastNonIdleCaptureTime: 100,
            presentationBacklogFrames: 2,
            latestPresentedFrameAgeMs: 150,
            receiverPlayoutDelayTargetMs: 120,
            receiverAckLagMs: 170,
            lastReceiverAckTime: 99.8
        )

        #expect(!(await context.receiverFrameBudgetCanRaiseQuality(now: 100)))
    }

    @Test("AWDL receiver feedback must be fresh before host quality raises")
    func awdlReceiverFeedbackMustBeFreshBeforeHostQualityRaises() async {
        let context = makeContext(latencyMode: .balanced, mediaPathProfile: .awdlRadio)

        #expect(!(await context.receiverFrameBudgetIsHealthy(now: 100)))
        #expect(!(await context.receiverFrameBudgetCanRaiseQuality(now: 100)))
        #expect(await context.receiverFrameBudgetCapacityLearningQuarantineReason(now: 100) == "receiver-feedback-stale")

        await context.configureReceiverFreshnessForTesting(
            now: 100,
            lastInputTime: 100,
            lastNonIdleCaptureTime: 100,
            presentationBacklogFrames: 2,
            latestPresentedFrameAgeMs: 120,
            receiverPlayoutDelayTargetMs: 120
        )

        #expect(await context.receiverFrameBudgetIsHealthy(now: 101))
        #expect(await context.receiverFrameBudgetCanRaiseQuality(now: 101))
        #expect(!(await context.receiverFrameBudgetIsHealthy(now: 103)))
        #expect(!(await context.receiverFrameBudgetCanRaiseQuality(now: 103)))
    }

    @Test("Most Responsive treats one pending presentation frame as fresh during input")
    func mostResponsiveAllowsOnePendingPresentationFrameDuringInput() {
        let policy = HostFrameFreshnessPolicy.policy(for: .lowestLatency, frameRate: 60)

        #expect(policy.allowsPresentationFreshness(
            depth: 1,
            latestPresentedFrameAgeMs: 50,
            inputActive: true,
            sourceStill: false
        ))
        #expect(!policy.allowsPresentationFreshness(
            depth: 2,
            latestPresentedFrameAgeMs: 50,
            inputActive: true,
            sourceStill: false
        ))
    }

    @Test("AWDL freshness policy allows bounded playout age during input")
    func awdlFreshnessPolicyAllowsBoundedPlayoutAgeDuringInput() {
        let policy = HostFrameFreshnessPolicy.policy(
            for: .balanced,
            frameRate: 60,
            mediaPathProfile: .awdlRadio,
            receiverPlayoutDelayTargetMs: 120
        )

        #expect(policy.allowsPresentationFreshness(
            depth: 2,
            latestPresentedFrameAgeMs: 150,
            inputActive: true,
            sourceStill: false
        ))
        #expect(!policy.allowsPresentationFreshness(
            depth: 3,
            latestPresentedFrameAgeMs: 150,
            inputActive: true,
            sourceStill: false
        ))
        #expect(!policy.allowsPresentationFreshness(
            depth: 2,
            latestPresentedFrameAgeMs: 210,
            inputActive: true,
            sourceStill: false
        ))
    }

    @Test("Still content ignores presented frame age and allows elastic presentation backlog")
    func stillContentAllowsElasticPresentationBacklog() {
        let policy = HostFrameFreshnessPolicy.policy(for: .lowestLatency, frameRate: 60)

        #expect(policy.allowsPresentationFreshness(
            depth: 3,
            latestPresentedFrameAgeMs: 2_000,
            inputActive: false,
            sourceStill: true
        ))
        #expect(!policy.allowsPresentationFreshness(
            depth: 4,
            latestPresentedFrameAgeMs: 2_000,
            inputActive: false,
            sourceStill: true
        ))
    }

    @Test("High-motion input holds stale queued P-frames before they deepen latency")
    func inputMotionHoldsStaleQueuedPFrames() {
        let policy = HostFrameFreshnessPolicy.policy(for: .lowestLatency, frameRate: 60)

        #expect(!policy.shouldHoldPFrameReservation(
            unstartedPFrameCount: 1,
            oldestUnstartedPFrameAgeMs: 10,
            oldestUnstartedPFrameLatenessMs: 0,
            lateReservedPFrameStreak: 0,
            inputActive: true,
            sourceStill: false
        ))
        #expect(policy.shouldHoldPFrameReservation(
            unstartedPFrameCount: 2,
            oldestUnstartedPFrameAgeMs: 10,
            oldestUnstartedPFrameLatenessMs: 0,
            lateReservedPFrameStreak: 0,
            inputActive: true,
            sourceStill: false
        ))
        #expect(policy.shouldHoldPFrameReservation(
            unstartedPFrameCount: 1,
            oldestUnstartedPFrameAgeMs: 10,
            oldestUnstartedPFrameLatenessMs: 1,
            lateReservedPFrameStreak: 1,
            inputActive: true,
            sourceStill: false
        ))
    }

    @Test("Still queued P-frames get more elasticity without becoming unbounded")
    func stillQueuedPFramesAreElasticButBounded() {
        let policy = HostFrameFreshnessPolicy.policy(for: .lowestLatency, frameRate: 60)

        #expect(!policy.shouldHoldPFrameReservation(
            unstartedPFrameCount: 3,
            oldestUnstartedPFrameAgeMs: 120,
            oldestUnstartedPFrameLatenessMs: 20,
            lateReservedPFrameStreak: 1,
            inputActive: false,
            sourceStill: true
        ))
        #expect(policy.shouldHoldPFrameReservation(
            unstartedPFrameCount: 4,
            oldestUnstartedPFrameAgeMs: 120,
            oldestUnstartedPFrameLatenessMs: 20,
            lateReservedPFrameStreak: 1,
            inputActive: false,
            sourceStill: true
        ))
        #expect(policy.shouldHoldPFrameReservation(
            unstartedPFrameCount: 1,
            oldestUnstartedPFrameAgeMs: 240,
            oldestUnstartedPFrameLatenessMs: 0,
            lateReservedPFrameStreak: 0,
            inputActive: false,
            sourceStill: true
        ))
    }

    @Test("Receiver presentation target depth is normalized before host pressure gates")
    func receiverPresentationTargetDepthIsNormalizedBeforeHostPressureGates() async {
        let context = makeContext(latencyMode: .balanced)
        let healthyBufferedPlayout = receiverFeedback(
            presentationQueueDepth: 5,
            presentationTargetFrames: 5
        )

        let healthyDepth = await context.resolvedReceiverPresentationBacklogFrames(healthyBufferedPlayout)
        await context.updateReceiverCapacityLearningQuarantine(healthyBufferedPlayout, now: 100)

        #expect(healthyDepth == 0)
        #expect(await context.receiverCapacityLearningQuarantineReason == nil)

        let backloggedPlayout = receiverFeedback(
            presentationQueueDepth: 9,
            presentationTargetFrames: 5
        )
        let backlogDepth = await context.resolvedReceiverPresentationBacklogFrames(backloggedPlayout)
        await context.updateReceiverCapacityLearningQuarantine(backloggedPlayout, now: 101)

        #expect(backlogDepth == 4)
        #expect(await context.receiverCapacityLearningQuarantineReason == "presentation-backlog")
    }

    @Test("Receiver presentation stalls are classified as underflow")
    func receiverPresentationStallsAreClassifiedAsUnderflow() async {
        let context = makeContext(latencyMode: .balanced)
        let underfilledPlayout = receiverFeedback(presentationStallCount: 1)

        await context.updateReceiverCapacityLearningQuarantine(underfilledPlayout, now: 100)

        #expect(await context.receiverCapacityLearningQuarantineReason == "presentation-underflow")
    }

    @Test("AWDL quality cuts require applied survival cadence and scale")
    func awdlQualityCutsRequireAppliedSurvivalCadenceAndScale() async {
        let context = makeContext(latencyMode: .lowestLatency, mediaPathProfile: .awdlRadio)

        await context.seedAwdlSurvivalDecisionForTesting()

        await context.setAwdlAppliedDemotionForTesting(frameRate: 60, streamScale: 1.0, baseScale: 1.0)
        #expect(!(await context.currentAwdlFrameBudgetReductionAllowed()))

        await context.setAwdlAppliedDemotionForTesting(frameRate: 30, streamScale: 0.875, baseScale: 1.0)
        #expect(!(await context.currentAwdlFrameBudgetReductionAllowed()))

        await context.setAwdlAppliedDemotionForTesting(frameRate: 30, streamScale: 0.75, baseScale: 1.0)
        #expect(await context.currentAwdlFrameBudgetReductionAllowed())
    }

    @Test("AWDL survival quality window expires")
    func awdlSurvivalQualityWindowExpires() async {
        let context = makeContext(latencyMode: .lowestLatency, mediaPathProfile: .awdlRadio)

        await context.setAwdlAppliedDemotionForTesting(frameRate: 30, streamScale: 0.75, baseScale: 1.0)
        await context.grantAwdlHostStructuralQualityReduction(now: CFAbsoluteTimeGetCurrent(), reason: "test")
        let deadline = await context.awdlHostEncoderStructuralQualityReductionDeadline

        #expect(await context.currentAwdlFrameBudgetReductionAllowed(now: deadline - 0.1))
        #expect(!(await context.currentAwdlFrameBudgetReductionAllowed(now: deadline + 0.1)))
    }

    private func makeContext(
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown
    ) -> StreamContext {
        let encoderConfig = MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            colorDepth: .pro,
            colorSpace: .displayP3,
            pixelFormat: .bgr10a2,
            bitrate: 600_000_000
        )
        return StreamContext(
            streamID: 1,
            windowID: 0,
            encoderConfig: encoderConfig,
            streamScale: 1.0,
            runtimeQualityAdjustmentEnabled: true,
            latencyMode: latencyMode,
            mediaPathProfile: mediaPathProfile
        )
    }

    private func receiverFeedback(
        presentationQueueDepth: Int? = nil,
        presentationTargetFrames: Int? = nil,
        presentationStallCount: UInt64? = nil
    ) -> MirageWire.ReceiverMediaFeedbackMessage {
        MirageWire.ReceiverMediaFeedbackMessage(
            streamID: 1,
            sequence: 1,
            sentAtUptime: 0,
            targetFPS: 60,
            ackRanges: [],
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
            presentationStallCount: presentationStallCount,
            presentationQueueDepth: presentationQueueDepth,
            presentationTargetFrames: presentationTargetFrames
        )
    }
}

private extension StreamContext {
    func configureReceiverFreshnessForTesting(
        now: CFAbsoluteTime,
        lastInputTime: CFAbsoluteTime,
        lastNonIdleCaptureTime: CFAbsoluteTime,
        reassemblyBacklogFrames: Int = 0,
        reassemblyBacklogBytes: Int = 0,
        decodeBacklogFrames: Int = 0,
        presentationBacklogFrames: Int,
        latestPresentedFrameAgeMs: Double,
        receiverPlayoutDelayTargetMs: Double? = nil,
        receiverAckLagMs: Double? = nil,
        lastReceiverAckTime: CFAbsoluteTime = 0
    ) {
        lastReceiverFeedbackTime = now
        lastClientInputTime = lastInputTime
        self.lastNonIdleCapturedFrameTime = lastNonIdleCaptureTime
        receiverReassemblyBacklogFrames = reassemblyBacklogFrames
        receiverReassemblyBacklogBytes = reassemblyBacklogBytes
        receiverDecodeBacklogFrames = decodeBacklogFrames
        receiverPresentationBacklogFrames = presentationBacklogFrames
        receiverLatestPresentedFrameAgeMs = latestPresentedFrameAgeMs
        receiverLostFrameCount = 0
        receiverDiscardedPacketCount = 0
        self.receiverPlayoutDelayTargetMs = receiverPlayoutDelayTargetMs
        self.receiverAckLagMs = receiverAckLagMs
        self.lastReceiverAckTime = lastReceiverAckTime
    }

    func seedAwdlSurvivalDecisionForTesting() {
        for sequence in 1...8 {
            _ = transportController.update(
                with: MirageWire.ReceiverMediaFeedbackMessage(
                    streamID: streamID,
                    sequence: UInt64(sequence),
                    sentAtUptime: 0,
                    targetFPS: 60,
                    ackRanges: [],
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
                    pFrameCompletionLatencyP95Ms: 80,
                    latePFrameCount: 4
                ),
                currentFrameRate: currentFrameRate,
                transportPathKind: .awdl,
                mediaPathProfile: .awdlRadio,
                now: Double(sequence)
            )
        }
        grantAwdlHostStructuralQualityReduction(now: CFAbsoluteTimeGetCurrent(), reason: "test-survival")
    }

    func setAwdlAppliedDemotionForTesting(
        frameRate: Int,
        streamScale: CGFloat,
        baseScale: CGFloat
    ) {
        currentFrameRate = frameRate
        self.streamScale = streamScale
        awdlInteractiveBaseStreamScale = baseScale
    }
}
#endif
