//
//  StreamPacketSenderPacingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//

@testable import MirageKitHost
import CoreGraphics
import CoreMedia
import Foundation
import MirageKit
import Testing

#if os(macOS)
@Suite("Stream Packet Sender Pacing")
struct StreamPacketSenderPacingTests {
    @Test("Pacer sleep is zero when projected debt stays within tolerance")
    func packetPacerSleepWithinTolerance() {
        let sleepMs = StreamPacketSender.packetPacerSleepMilliseconds(
            tokensBeforeSend: 2_000,
            packetBytes: 2_800,
            bytesPerMillisecond: 1_000,
            debtToleranceMs: 1.0,
            maxSleepMs: 12
        )
        #expect(sleepMs == 0)
    }

    @Test("Pacer sleep rounds up to recover debt beyond tolerance")
    func packetPacerSleepForDebtRecovery() {
        let sleepMs = StreamPacketSender.packetPacerSleepMilliseconds(
            tokensBeforeSend: 500,
            packetBytes: 4_500,
            bytesPerMillisecond: 1_000,
            debtToleranceMs: 1.0,
            maxSleepMs: 12
        )
        #expect(sleepMs == 3)
    }

    @Test("Pacer sleep clamps to configured max when debt is large")
    func packetPacerSleepClampsToMax() {
        let sleepMs = StreamPacketSender.packetPacerSleepMilliseconds(
            tokensBeforeSend: -20_000,
            packetBytes: 8_000,
            bytesPerMillisecond: 1_000,
            debtToleranceMs: 1.0,
            maxSleepMs: 12
        )
        #expect(sleepMs == 12)
    }

    @Test("Keyframe burst window remains stable across keyframe sizes")
    func keyframeBurstWindowIsStableAcrossSizes() {
        let baseline = StreamPacketSender.packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: true,
            totalFragments: 100
        )
        let large = StreamPacketSender.packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: true,
            totalFragments: 400
        )
        let huge = StreamPacketSender.packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: true,
            totalFragments: 800
        )

        #expect(large == baseline)
        #expect(huge == baseline)
    }

    @Test("Steady-state burst window is smaller than keyframe burst window")
    func steadyStateBurstWindowIsSmallerThanKeyframeBurst() {
        let steadyState = StreamPacketSender.packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: false,
            totalFragments: 1
        )
        let keyframe = StreamPacketSender.packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: true,
            totalFragments: 100
        )

        #expect(steadyState < keyframe)
    }

    @Test("Non-keyframe packets participate in pacing parameters")
    func nonKeyframePacketsParticipateInPacing() {
        let steadyState = StreamPacketSender.packetPacingParameters(
            targetRateBps: 600_000_000,
            packetBytes: 1400,
            isKeyframeBurst: false,
            totalFragments: 1,
            pacingOverride: nil
        )
        let keyframe = StreamPacketSender.packetPacingParameters(
            targetRateBps: 600_000_000,
            packetBytes: 1400,
            isKeyframeBurst: true,
            totalFragments: 900,
            pacingOverride: nil
        )

        #expect(steadyState != nil)
        #expect(keyframe != nil)
        #expect(steadyState?.burstBytes ?? 0 < keyframe?.burstBytes ?? 0)
    }

    @Test("Non-keyframes can burst for one frame budget while keyframes keep startup pacing")
    func nonKeyframeFrameBudgetBurstPreservesKeyframePacing() {
        let nonKeyframe = StreamPacketSender.packetPacingParameters(
            targetRateBps: 600_000_000,
            packetBytes: 1400,
            isKeyframeBurst: false,
            totalFragments: 1,
            targetFrameIntervalMs: 1000.0 / 60.0,
            pacingOverride: nil
        )
        let cappedNonKeyframe = StreamPacketSender.packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: false,
            totalFragments: 1,
            targetFrameIntervalMs: 1000.0 / 30.0
        )
        let keyframeWindow = StreamPacketSender.packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: true,
            totalFragments: 100,
            targetFrameIntervalMs: 1000.0 / 60.0
        )

        #expect(nonKeyframe != nil)
        #expect((nonKeyframe?.burstBytes ?? 0) > 1400)
        #expect(cappedNonKeyframe == 16.7)
        #expect(keyframeWindow == StreamPacketSender.packetPacerBurstWindowMs)
    }

    @Test("Packet budget includes FEC parity payload when wire bytes omit it")
    func packetBudgetIncludesFECParityPayloadWhenWireBytesOmitIt() async {
        let payload = Data(repeating: 0xA5, count: 1025)
        let maxPayloadSize = 512
        let fecBlockSize = 2
        let sender = StreamPacketSender(
            maxPayloadSize: maxPayloadSize,
            sendPacket: { _, onComplete in
                onComplete(nil)
            }
        )

        await sender.start()
        await sender.setTargetBitrateBps(200_000_000)
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            StreamPacketSender.WorkItem(
                encodedData: payload,
                frameByteCount: payload.count,
                isKeyframe: false,
                presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
                contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                streamID: 14,
                frameNumber: 34,
                sequenceNumberStart: 5000,
                additionalFlags: [],
                dimensionToken: 0,
                epoch: 0,
                fecBlockSize: fecBlockSize,
                wireBytes: payload.count,
                logPrefix: "test",
                generation: generation,
                encodedAt: CFAbsoluteTimeGetCurrent(),
                pacingOverride: nil
            )
        )

        guard let snapshot = await sender.packetBudgetSnapshot() else {
            Issue.record("Missing packet budget snapshot")
            await sender.stop()
            return
        }

        let dataFragments = (payload.count + maxPayloadSize - 1) / maxPayloadSize
        let parityFragments = (dataFragments + fecBlockSize - 1) / fecBlockSize
        let payloadBudget = payload.count + parityFragments * maxPayloadSize
        let packetOverhead = (dataFragments + parityFragments) * mirageHeaderSize
        #expect(snapshot.sampleBytes >= payloadBudget + packetOverhead)
        #expect(snapshot.sampleBytes > payload.count + dataFragments * mirageHeaderSize)

        await sender.stop()
    }
}
#endif
