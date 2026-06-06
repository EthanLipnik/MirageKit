//
//  FrameReassemblerPacketAcceptanceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/2/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing
import MirageWire

#if os(macOS)
@Suite("Frame Reassembler Packet Acceptance")
struct FrameReassemblerPacketAcceptanceTests {
    @Test("Dimension-token rejects count as raw packets but not accepted media")
    func dimensionTokenRejectsDoNotCountAsAcceptedPackets() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)
        reassembler.updateExpectedDimensionToken(7)

        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x00])
        reassembler.processPacket(
            payload,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 1,
                payload: payload,
                fragmentIndex: 0,
                fragmentCount: 1,
                dimensionToken: 6
            )
        )

        let snapshot = reassembler.packetAcceptanceSnapshot
        #expect(snapshot.rawPacketsReceived == 1)
        #expect(snapshot.acceptedPacketsReceived == 0)
        #expect(reassembler.keyframeWaitSnapshot.latestAcceptedPacketReceivedTime == 0)
        #expect(reassembler.hasReceivedPackets == true)
        #expect(reassembler.hasAcceptedPackets == false)
        #expect(reassembler.isAwaitingKeyframe == true)
    }

    @Test("CRC rejects count as raw packets but not accepted media")
    func crcRejectsDoNotCountAsAcceptedPackets() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)

        let payload = Data([0x10, 0x20, 0x30])
        reassembler.processPacket(
            payload,
            header: MirageWire.FrameHeader(
                flags: [.keyframe, .endOfFrame],
                streamID: 1,
                sequenceNumber: 1,
                timestamp: 1,
                frameNumber: 1,
                fragmentIndex: 0,
                fragmentCount: 1,
                payloadLength: UInt32(payload.count),
                frameByteCount: UInt32(payload.count),
                checksum: 0,
                contentRect: .zero,
                dimensionToken: 0,
                epoch: 0
            )
        )

        let snapshot = reassembler.packetAcceptanceSnapshot
        #expect(snapshot.rawPacketsReceived == 1)
        #expect(snapshot.acceptedPacketsReceived == 0)
        #expect(reassembler.keyframeWaitSnapshot.latestAcceptedPacketReceivedTime == 0)
        #expect(reassembler.hasReceivedPackets == true)
        #expect(reassembler.hasAcceptedPackets == false)
        #expect(reassembler.packetsDiscardedCRC == 1)
    }

    @Test("Valid packets count as accepted media and reset clears packet flow")
    func acceptedPacketSnapshotTracksValidPacketsAndResetClearsFlow() {
        let reassembler = FrameReassembler(streamID: 1, maxPayloadSize: 1200)

        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x00])
        reassembler.processPacket(
            payload,
            header: makeHeader(
                flags: [.keyframe, .endOfFrame],
                frameNumber: 1,
                payload: payload,
                fragmentIndex: 0,
                fragmentCount: 1
            )
        )

        var snapshot = reassembler.packetAcceptanceSnapshot
        #expect(snapshot.rawPacketsReceived == 1)
        #expect(snapshot.acceptedPacketsReceived == 1)
        #expect(reassembler.keyframeWaitSnapshot.latestAcceptedPacketReceivedTime > 0)
        #expect(reassembler.hasAcceptedPackets == true)

        reassembler.reset()

        snapshot = reassembler.packetAcceptanceSnapshot
        #expect(snapshot.rawPacketsReceived == 0)
        #expect(snapshot.acceptedPacketsReceived == 0)
        #expect(reassembler.hasReceivedPackets == false)
        #expect(reassembler.hasAcceptedPackets == false)
    }
}
#endif
