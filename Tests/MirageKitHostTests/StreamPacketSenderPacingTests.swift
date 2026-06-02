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

    @Test("Bitrate retunes preserve token debt")
    func bitrateRetunesPreserveTokenDebt() {
        let debt = -24_000.0
        let retunedDebt = StreamPacketSender.retunedPacketPacerTokens(
            currentTokensBytes: debt,
            oldRateBps: 80_000_000,
            newRateBps: 40_000_000,
            maxPayloadSize: 1_200
        )

        #expect(retunedDebt < 0)
        #expect(abs(retunedDebt - debt * 0.5) < 0.001)
    }

    @Test("Bitrate retunes clamp credit instead of creating a fresh burst")
    func bitrateRetunesClampCreditInsteadOfCreatingFreshBurst() {
        let retunedCredit = StreamPacketSender.retunedPacketPacerTokens(
            currentTokensBytes: 80_000,
            oldRateBps: 40_000_000,
            newRateBps: 80_000_000,
            maxPayloadSize: 1_200
        )
        let expectedBurst = Double(80_000_000) / 8.0 / 1_000.0 *
            StreamPacketSender.packetPacerSteadyStateFrameBurstMaxWindowMs

        #expect(retunedCredit == expectedBurst)
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

    @Test("FEC parity is interleaved after each protected data block")
    func fecParityIsInterleavedAfterEachProtectedDataBlock() {
        let order = StreamPacketSender.fragmentSendOrder(
            dataFragmentCount: 10,
            parityFragmentCount: 3,
            fecBlockSize: 4
        )

        #expect(order == [0, 1, 2, 3, 10, 4, 5, 6, 7, 11, 8, 9, 12])
        #expect(order.last == 12)
    }

    @Test("FEC block size one is treated as disabled")
    func fecBlockSizeOneIsTreatedAsDisabled() {
        let plan = StreamPacketSender.fragmentPlan(
            frameByteCount: 10,
            maxPayload: 4,
            fecBlockSize: 1
        )
        let order = StreamPacketSender.fragmentSendOrder(
            dataFragmentCount: plan.dataFragmentCount,
            parityFragmentCount: plan.parityFragmentCount,
            fecBlockSize: 1
        )

        #expect(plan.dataFragmentCount == 3)
        #expect(plan.parityFragmentCount == 0)
        #expect(order == [0, 1, 2])
    }

    @Test("FEC fragment planning sequence reservation and queue bytes agree")
    func fecFragmentPlanningSequenceReservationAndQueueBytesAgree() {
        let sender = StreamPacketSender(
            maxPayloadSize: 4,
            sendPacketWithMetadata: { _, _, onComplete in onComplete(nil) }
        )
        let sequencer = StreamEncodingCallbackSequencer()
        var expectedSequenceNumber: UInt32 = 0

        for blockSize in [0, 4, 8] {
            let plan = StreamPacketSender.fragmentPlan(
                frameByteCount: 10,
                maxPayload: 4,
                fecBlockSize: blockSize
            )
            let reservation = sequencer.reserve(
                frameByteCount: 10,
                maxPayloadSize: 4,
                fecBlockSize: blockSize
            )
            let item = makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 10),
                streamID: 9,
                frameNumber: UInt32(blockSize),
                sequenceNumberStart: reservation.sequenceNumberStart,
                generation: sender.currentGeneration,
                fecBlockSize: blockSize
            )
            let expectedWireBytes = 10 + plan.parityFragmentCount * 4

            #expect(reservation.sequenceNumberStart == expectedSequenceNumber)
            #expect(reservation.wireBytes == expectedWireBytes)
            #expect(sender.accountedWireBytes(for: item) == expectedWireBytes)

            expectedSequenceNumber &+= UInt32(plan.totalFragmentCount)
        }
    }

    @Test("Fragment send order stays sequential when FEC is disabled")
    func fragmentSendOrderStaysSequentialWhenFECIsDisabled() {
        let order = StreamPacketSender.fragmentSendOrder(
            dataFragmentCount: 5,
            parityFragmentCount: 0,
            fecBlockSize: 0
        )

        #expect(order == [0, 1, 2, 3, 4])
    }
}
#endif
