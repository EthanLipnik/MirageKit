//
//  StreamPacketSenderPacingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import CoreMedia
import Foundation
import MirageKit
import Testing

@Suite("Stream Packet Sender Pacing")
struct StreamPacketSenderPacingTests {

    @Test("Steady-state non-keyframe pacing uses a sub-frame burst window")
    func steadyStateNonKeyframePacingUsesSubFrameBurstWindow() {
        let sixtyHzWindow = StreamPacketSender.packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: false,
            totalFragments: 12,
            targetFrameIntervalMs: 1000.0 / 60.0
        )
        let thirtyHzWindow = StreamPacketSender.packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: false,
            totalFragments: 12,
            targetFrameIntervalMs: 1000.0 / 30.0
        )
        let oneTwentyHzWindow = StreamPacketSender.packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: false,
            totalFragments: 12,
            targetFrameIntervalMs: 1000.0 / 120.0
        )
        let keyframeWindow = StreamPacketSender.packetPacerBurstWindowMilliseconds(
            isKeyframeBurst: true,
            totalFragments: 120,
            targetFrameIntervalMs: 1000.0 / 60.0
        )

        #expect(sixtyHzWindow == StreamPacketSender.packetPacerSteadyStateFrameBurstMaxWindowMs)
        #expect(thirtyHzWindow == StreamPacketSender.packetPacerSteadyStateFrameBurstMaxWindowMs)
        #expect(oneTwentyHzWindow < sixtyHzWindow)
        #expect(sixtyHzWindow < 1000.0 / 60.0)
        #expect(keyframeWindow == StreamPacketSender.packetPacerBurstWindowMs)
    }

    @Test("Non-keyframe packet budget is capped below a full frame burst")
    func nonKeyframePacketBudgetIsCappedBelowFullFrameBurst() throws {
        let targetRateBps = 80_000_000
        let bytesPerMillisecond = Double(targetRateBps) / 8.0 / 1_000.0
        let frameIntervalMs = 1000.0 / 60.0
        let parameters = try #require(StreamPacketSender.packetPacingParameters(
            targetRateBps: targetRateBps,
            packetBytes: 1_200,
            isKeyframeBurst: false,
            totalFragments: 32,
            targetFrameIntervalMs: frameIntervalMs,
            pacingOverride: nil
        ))

        #expect(parameters.burstBytes <= bytesPerMillisecond * StreamPacketSender.packetPacerSteadyStateFrameBurstMaxWindowMs)
        #expect(parameters.burstBytes < bytesPerMillisecond * frameIntervalMs)
        #expect(parameters.burstBytes > 1_200)
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

    @Test("Fragment plans reject header counts that cannot fit on the wire")
    func fragmentPlansRejectHeaderCountsThatCannotFitOnTheWire() {
        let maxPayloadSize = 512
        let largestRepresentableByteCount = Int(UInt16.max) * maxPayloadSize
        let representablePlan = StreamPacketSender.fragmentPlan(
            frameByteCount: largestRepresentableByteCount,
            maxPayload: maxPayloadSize,
            fecBlockSize: 0
        )
        let oversizedPlan = StreamPacketSender.fragmentPlan(
            frameByteCount: largestRepresentableByteCount + 1,
            maxPayload: maxPayloadSize,
            fecBlockSize: 0
        )

        #expect(representablePlan.totalFragmentCount == Int(UInt16.max))
        #expect(StreamPacketSender.canRepresentFragmentPlan(
            representablePlan,
            frameByteCount: largestRepresentableByteCount
        ))
        #expect(oversizedPlan.totalFragmentCount == Int(UInt16.max) + 1)
        #expect(!StreamPacketSender.canRepresentFragmentPlan(
            oversizedPlan,
            frameByteCount: largestRepresentableByteCount + 1
        ))
    }

    @Test("Fragment plans account for FEC parity before UInt16 header conversion")
    func fragmentPlansAccountForFECParityBeforeUInt16HeaderConversion() {
        let maxPayloadSize = 512
        let byteCountWithMaximumDataFragments = Int(UInt16.max) * maxPayloadSize
        let plan = StreamPacketSender.fragmentPlan(
            frameByteCount: byteCountWithMaximumDataFragments,
            maxPayload: maxPayloadSize,
            fecBlockSize: 2
        )

        #expect(plan.dataFragmentCount == Int(UInt16.max))
        #expect(plan.parityFragmentCount > 0)
        #expect(plan.totalFragmentCount > Int(UInt16.max))
        #expect(!StreamPacketSender.canRepresentFragmentPlan(
            plan,
            frameByteCount: byteCountWithMaximumDataFragments
        ))
    }

    @Test("Fragment plans reject frame byte counts that cannot fit in header")
    func fragmentPlansRejectFrameByteCountsThatCannotFitInHeader() {
        let plan = StreamPacketSender.fragmentPlan(
            frameByteCount: Int(UInt32.max) + 1,
            maxPayload: Int(UInt32.max) + 1,
            fecBlockSize: 0
        )

        #expect(plan.totalFragmentCount == 1)
        #expect(!StreamPacketSender.canRepresentFragmentPlan(
            plan,
            frameByteCount: Int(UInt32.max) + 1
        ))
    }
}
#endif
