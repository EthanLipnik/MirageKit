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
    @Test("Auto mode applies burst overrides and restores baseline on expiry")
    func autoModeBurstActivationAndExpiry() async {
        let context = makeContext(latencyMode: .auto)
        let baseline = await context.typingBurstSnapshot()
        #expect(!baseline.isActive)

        await context.noteTypingBurstActivity(at: 100.0, scheduleExpiry: false)
        let active = await context.typingBurstSnapshot()
        #expect(active.isActive)
        #expect(abs(active.deadline - 100.35) < 0.0001)
        #expect(active.maxInFlightFrames == 1)
        #expect(abs(active.qualityCeiling - 0.62) < 0.0001)

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
        #expect(!restored.isActive)
        #expect(restored.maxInFlightFrames == baseline.maxInFlightFrames)
        #expect(abs(restored.qualityCeiling - baseline.qualityCeiling) < 0.0001)
        #expect(abs(restored.activeQuality - baseline.activeQuality) < 0.0001)
    }

    @Test("Non-auto modes ignore typing burst activity")
    func nonAutoModesIgnoreTypingBurst() async {
        let context = makeContext(latencyMode: .lowestLatency)
        await context.noteTypingBurstActivity(at: 200.0, scheduleExpiry: false)
        let snapshot = await context.typingBurstSnapshot()
        #expect(!snapshot.isActive)
        #expect(snapshot.maxInFlightFrames == 1)
    }

    @Test("Stream context default latency mode behaves as auto")
    func streamContextDefaultModeIsAuto() async {
        let config = MirageEncoderConfiguration(targetFrameRate: 60)
        let context = StreamContext(
            streamID: 99,
            windowID: 0,
            encoderConfig: config
        )

        await context.noteTypingBurstActivity(at: 300.0, scheduleExpiry: false)
        let snapshot = await context.typingBurstSnapshot()
        #expect(snapshot.isActive)
        #expect(snapshot.maxInFlightFrames == 1)
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
