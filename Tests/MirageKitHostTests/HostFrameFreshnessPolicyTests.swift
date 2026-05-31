//
//  HostFrameFreshnessPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/31/26.
//

#if os(macOS)
import CoreFoundation
@testable import MirageKit
@testable import MirageKitHost
import Testing

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
            presentationBacklogFrames: 4,
            latestPresentedFrameAgeMs: 2_000
        )

        #expect(await context.receiverFrameBudgetCanRaiseQuality(now: 100))
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

    @Test("Still content ignores presented frame age and allows elastic presentation backlog")
    func stillContentAllowsElasticPresentationBacklog() {
        let policy = HostFrameFreshnessPolicy.policy(for: .lowestLatency, frameRate: 60)

        #expect(policy.allowsPresentationFreshness(
            depth: 4,
            latestPresentedFrameAgeMs: 2_000,
            inputActive: false,
            sourceStill: true
        ))
        #expect(!policy.allowsPresentationFreshness(
            depth: 5,
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

    private func makeContext(latencyMode: MirageStreamLatencyMode) -> StreamContext {
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
            latencyMode: latencyMode
        )
    }
}

private extension StreamContext {
    func configureReceiverFreshnessForTesting(
        now: CFAbsoluteTime,
        lastInputTime: CFAbsoluteTime,
        lastNonIdleCaptureTime: CFAbsoluteTime,
        decodeBacklogFrames: Int = 0,
        presentationBacklogFrames: Int,
        latestPresentedFrameAgeMs: Double
    ) {
        lastReceiverFeedbackTime = now
        lastClientInputTime = lastInputTime
        self.lastNonIdleCapturedFrameTime = lastNonIdleCaptureTime
        receiverReassemblyBacklogFrames = 0
        receiverReassemblyBacklogBytes = 0
        receiverDecodeBacklogFrames = decodeBacklogFrames
        receiverPresentationBacklogFrames = presentationBacklogFrames
        receiverLatestPresentedFrameAgeMs = latestPresentedFrameAgeMs
        receiverLostFrameCount = 0
        receiverDiscardedPacketCount = 0
        lastReceiverAckTime = 0
    }
}
#endif
