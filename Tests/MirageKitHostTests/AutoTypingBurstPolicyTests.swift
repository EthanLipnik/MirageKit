//
//  AutoTypingBurstPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Coverage for auto-latency typing burst policy behavior.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Auto Typing Burst Policy")
struct AutoTypingBurstPolicyTests {
    @Test("Auto mode applies burst overrides and expires without quality rebound")
    func autoModeBurstActivationAndExpiry() async {
        let context = makeContext(latencyMode: .auto)
        let baseline = await context.typingBurstSnapshot()
        #expect(!baseline.isActive)
        #expect(!baseline.latencyBurstActive)
        #expect(baseline.maxInFlightFrames == 3)
        #expect(baseline.captureQueueDepthOverride == nil)
        #expect(!baseline.newestFrameDrainEnabled)

        await context.noteTypingBurstActivity(at: 100.0, scheduleExpiry: false)
        let active = await context.typingBurstSnapshot()
        let activeSettings = await context.getEncoderSettings()
        #expect(active.isActive)
        #expect(active.latencyBurstActive)
        #expect(abs(active.deadline - 100.35) < 0.0001)
        #expect(active.maxInFlightFrames == 1)
        #expect(active.captureQueueDepthOverride == 2)
        #expect(active.newestFrameDrainEnabled)
        #expect(activeSettings.captureQueueDepth == 2)
        #expect(abs(active.qualityCeiling - baseline.qualityCeiling) < 0.0001)
        #expect(abs(active.activeQuality - baseline.activeQuality) < 0.0001)

        await context.noteTypingBurstActivity(at: 100.2, scheduleExpiry: false)
        let extended = await context.typingBurstSnapshot()
        #expect(extended.deadline > active.deadline)
        #expect(abs(extended.deadline - 100.55) < 0.0001)

        await context.expireTypingBurstIfNeeded(at: 100.4)
        let stillActive = await context.typingBurstSnapshot()
        #expect(stillActive.isActive)
        #expect(stillActive.maxInFlightFrames == 1)

        await context.expireTypingBurstIfNeeded(at: 100.56)
        let restored = await context.typingBurstSnapshot()
        let restoredSettings = await context.getEncoderSettings()
        #expect(!restored.isActive)
        #expect(!restored.latencyBurstActive)
        #expect(restored.maxInFlightFrames == baseline.maxInFlightFrames)
        #expect(restored.captureQueueDepthOverride == nil)
        #expect(!restored.newestFrameDrainEnabled)
        #expect(restoredSettings.captureQueueDepth == nil)
        #expect(abs(restored.qualityCeiling - baseline.qualityCeiling) < 0.0001)
        #expect(abs(restored.activeQuality - baseline.activeQuality) < 0.0001)
    }

    @Test("Auto mode keeps quality unchanged across burst expiry")
    func autoModeBurstQualityPreserved() async {
        let context = makeContext(latencyMode: .auto)
        let baseline = await context.typingBurstSnapshot()

        await context.noteTypingBurstActivity(at: 400.0, scheduleExpiry: false)
        let duringBurst = await context.typingBurstSnapshot()
        #expect(abs(duringBurst.activeQuality - baseline.activeQuality) < 0.0001)
        #expect(abs(duringBurst.qualityCeiling - baseline.qualityCeiling) < 0.0001)

        await context.noteTypingBurstActivity(at: 400.2, scheduleExpiry: false)
        await context.expireTypingBurstIfNeeded(at: 400.6)
        let afterBurst = await context.typingBurstSnapshot()
        #expect(!afterBurst.isActive)
        #expect(abs(afterBurst.activeQuality - baseline.activeQuality) < 0.0001)
    }

    @Test("Auto burst expiry restores smooth baseline in-flight target")
    func autoBurstExpiryRestoresSmoothBaselineTarget() async {
        let context = makeContext(latencyMode: .auto)
        let baseline = await context.typingBurstSnapshot()
        #expect(baseline.maxInFlightFrames == 3)

        await context.noteTypingBurstActivity(at: 20.0, scheduleExpiry: false)
        await context.expireTypingBurstIfNeeded(at: 20.36)
        let postBurst = await context.typingBurstSnapshot()
        #expect(postBurst.maxInFlightFrames == baseline.maxInFlightFrames)
    }

    @Test("Non-auto modes ignore typing burst activity")
    func nonAutoModesIgnoreTypingBurst() async {
        let context = makeContext(latencyMode: .lowestLatency)
        await context.noteTypingBurstActivity(at: 200.0, scheduleExpiry: false)
        let snapshot = await context.typingBurstSnapshot()
        #expect(!snapshot.isActive)
        #expect(!snapshot.latencyBurstActive)
        #expect(snapshot.maxInFlightFrames == 1)
        #expect(snapshot.captureQueueDepthOverride == nil)
        #expect(!snapshot.newestFrameDrainEnabled)
    }

    @Test("Stream context default latency mode behaves as lowest latency")
    func streamContextDefaultModeIsLowestLatency() async {
        let config = MirageEncoderConfiguration(targetFrameRate: 60)
        let context = StreamContext(
            streamID: 99,
            windowID: 0,
            encoderConfig: config
        )

        await context.noteTypingBurstActivity(at: 300.0, scheduleExpiry: false)
        let snapshot = await context.typingBurstSnapshot()
        #expect(!snapshot.isActive)
        #expect(!snapshot.latencyBurstActive)
        #expect(snapshot.maxInFlightFrames == 1)
        #expect(snapshot.captureQueueDepthOverride == nil)
    }

    private func makeContext(latencyMode: MirageStreamLatencyMode) -> StreamContext {
        let config = MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            colorSpace: .displayP3,
            pixelFormat: .p010,
            bitrate: 50_000_000
        )
        return StreamContext(
            streamID: 42,
            windowID: 0,
            encoderConfig: config,
            latencyMode: latencyMode
        )
    }
}
#endif
