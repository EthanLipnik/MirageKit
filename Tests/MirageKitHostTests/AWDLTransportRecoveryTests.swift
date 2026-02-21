//
//  AWDLTransportRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  AWDL transport send-error recovery behavior coverage.
//

@testable import MirageKitHost
import MirageKit
import Foundation
import Network
import Testing

#if os(macOS)
@Suite("AWDL Transport Recovery")
struct AWDLTransportRecoveryTests {
    @Test("Transport send-error tracker triggers one burst per cooldown window")
    func sendErrorTrackerCooldownBehavior() {
        var tracker = StreamContext.TransportSendErrorTracker(
            timestamps: [],
            lastRecoveryTime: 0,
            threshold: 6,
            window: 1.0,
            cooldown: 2.0
        )

        for index in 0 ..< 5 {
            let didRecover = tracker.record(now: Double(index) * 0.1)
            #expect(!didRecover)
        }
        let firstBurst = tracker.record(now: 0.5)
        #expect(firstBurst)

        for index in 0 ..< 6 {
            let didRecover = tracker.record(now: 0.6 + Double(index) * 0.1)
            #expect(!didRecover)
        }

        for index in 0 ..< 5 {
            let didRecover = tracker.record(now: 3.0 + Double(index) * 0.1)
            #expect(!didRecover)
        }
        let secondBurst = tracker.record(now: 3.5)
        #expect(secondBurst)
    }

    @Test("Stream context transport send-error burst triggers recovery path")
    func sendErrorBurstTriggersRecoveryPath() async {
        let context = makeContext()
        let error = NWError.posix(.ECONNRESET)

        for _ in 0 ..< 5 {
            #expect(!(await context.handleTransportSendError(error)))
        }
        #expect(await context.handleTransportSendError(error))

        #expect(await context.transportSendErrorBursts == 1)
        #expect(await context.pendingKeyframeReason == "Transport send error recovery keyframe")
        #expect(context.lossModeDeadline > CFAbsoluteTimeGetCurrent())
    }

    @Test("Parameter-set duplication gate only enables first keyframe parameter-set fragment")
    func parameterSetDuplicationGate() {
        #expect(
            StreamPacketSender.shouldDuplicateParameterSetPacket(
                isExperimentEnabled: true,
                isKeyframe: true,
                fragmentIndex: 0,
                flags: [.parameterSet, .keyframe]
            )
        )

        #expect(
            !StreamPacketSender.shouldDuplicateParameterSetPacket(
                isExperimentEnabled: false,
                isKeyframe: true,
                fragmentIndex: 0,
                flags: [.parameterSet, .keyframe]
            )
        )
        #expect(
            !StreamPacketSender.shouldDuplicateParameterSetPacket(
                isExperimentEnabled: true,
                isKeyframe: false,
                fragmentIndex: 0,
                flags: [.parameterSet]
            )
        )
        #expect(
            !StreamPacketSender.shouldDuplicateParameterSetPacket(
                isExperimentEnabled: true,
                isKeyframe: true,
                fragmentIndex: 1,
                flags: [.parameterSet, .keyframe]
            )
        )
        #expect(
            !StreamPacketSender.shouldDuplicateParameterSetPacket(
                isExperimentEnabled: true,
                isKeyframe: true,
                fragmentIndex: 0,
                flags: [.keyframe]
            )
        )
    }

    private func makeContext() -> StreamContext {
        let encoderConfig = MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            colorSpace: .displayP3,
            pixelFormat: .bgr10a2,
            bitrate: 120_000_000
        )
        return StreamContext(
            streamID: 99,
            windowID: 99,
            encoderConfig: encoderConfig,
            streamScale: 1.0
        )
    }
}
#endif
