//
//  StreamControllerMosaicMediaUnitReassemblerTests.swift
//  MirageKitClient
//
//  Created by Ethan Lipnik on 6/6/26.
//

import Foundation
@testable import MirageKitClient
@testable import MirageWire
import Testing

@Suite("StreamController Mosaic Media Unit Reassembler")
struct StreamControllerMosaicMediaUnitReassemblerTests {
    @Test("Mosaic media-unit reassembler completes fragmented unit")
    func mosaicMediaUnitReassemblerCompletesFragmentedUnit() async throws {
        let payload = Data([0, 1, 2, 3, 4, 5, 6, 7, 8])
        let packets = MirageMosaicMediaUnitPacketizer.packetize(MirageMosaicMediaUnitPacketizerInput(
            streamID: 19,
            packetSequenceStart: 10,
            timestamp: 30,
            tilePlanEpoch: 4,
            mediaEpoch: 5,
            mediaUnitIndex: 6,
            tileIndex: 7,
            transportGroupIndex: 8,
            presentationGroupIndex: 9,
            unitFrameNumber: 10,
            tileVersion: 11,
            dependencyVersion: 2,
            isKeyframe: false,
            isAtomicGroup: true,
            payload: payload,
            maximumPayloadBytes: 4
        ))
        let reassembler = StreamControllerMosaicMediaUnitReassembler(streamID: 19)

        #expect(reassembler.processPacket(packets[1]) == nil)
        #expect(reassembler.processPacket(packets[0]) == nil)
        let completed = try #require(reassembler.processPacket(packets[2]))

        #expect(completed.streamID == 19)
        #expect(completed.tilePlanEpoch == 4)
        #expect(completed.mediaUnitIndex == 6)
        #expect(completed.tileIndex == 7)
        #expect(completed.transportGroupIndex == 8)
        #expect(completed.presentationGroupIndex == 9)
        #expect(completed.unitFrameNumber == 10)
        #expect(completed.tileVersion == 11)
        #expect(completed.dependencyVersion == 2)
        #expect(!completed.isKeyframe)
        #expect(completed.isAtomicGroup)
        #expect(completed.payload == payload)
    }

    @Test("Mosaic media-unit reassembler rejects wrong stream and corrupt fragments")
    func mosaicMediaUnitReassemblerRejectsWrongStreamAndCorruptFragments() async {
        let payload = Data([1, 2, 3, 4])
        let packets = MirageMosaicMediaUnitPacketizer.packetize(MirageMosaicMediaUnitPacketizerInput(
            streamID: 20,
            packetSequenceStart: 1,
            timestamp: 1,
            tilePlanEpoch: 1,
            mediaEpoch: 1,
            mediaUnitIndex: 1,
            tileIndex: 1,
            transportGroupIndex: 1,
            presentationGroupIndex: 1,
            unitFrameNumber: 1,
            tileVersion: 1,
            dependencyVersion: 1,
            isKeyframe: true,
            isAtomicGroup: false,
            payload: payload,
            maximumPayloadBytes: 4
        ))
        let reassembler = StreamControllerMosaicMediaUnitReassembler(streamID: 21)
        #expect(reassembler.processPacket(packets[0]) == nil)

        var corrupt = packets[0]
        corrupt[MirageWire.mirageMosaicHeaderSize] = 0xFF
        let matchingReassembler = StreamControllerMosaicMediaUnitReassembler(streamID: 20)
        #expect(matchingReassembler.processPacket(corrupt) == nil)
    }
}
