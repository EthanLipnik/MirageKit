//
//  StreamPacketSenderPacingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//

@testable import MirageKitHost
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
}
#endif
