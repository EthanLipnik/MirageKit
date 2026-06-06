//
//  MirageMosaicPacketHeaderTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/6/26.
//

import Foundation
@testable import MirageWire
import Testing

@Suite("Mirage Mosaic Packet Header")
struct MirageMosaicPacketHeaderTests {
    @Test("Mosaic media-unit header round trips compact tile-plan references")
    func mosaicMediaUnitHeaderRoundTripsCompactTilePlanReferences() throws {
        let header = MirageMosaicPacketHeader(
            flags: [.keyframe, .parameterSet, .atomicGroup],
            streamID: 42,
            packetSequence: 700,
            timestamp: 123_000_000,
            tilePlanEpoch: 9,
            mediaEpoch: 11,
            mediaUnitIndex: 4,
            tileIndex: 3,
            transportGroupIndex: 2,
            presentationGroupIndex: 1,
            unitFrameNumber: 99,
            tileVersion: 27,
            dependencyVersion: 25,
            fragmentIndex: 0,
            fragmentCount: 3,
            fecBlockSize: 0,
            payloadLength: 512,
            unitByteCount: 1400,
            checksum: 0xDEAD_BEEF
        )

        let data = header.serialize()
        let decoded = try #require(MirageMosaicPacketHeader.deserialize(from: data))

        #expect(data.count == MirageWire.mirageMosaicHeaderSize)
        #expect(decoded == header)
        #expect(MirageWire.FrameHeader.deserialize(from: data) == nil)
    }

    @Test("Mosaic media-unit packetizer fragments one unit with stable references")
    func mosaicMediaUnitPacketizerFragmentsOneUnitWithStableReferences() throws {
        let payload = Data(0 ..< 10)
        let packets = MirageMosaicMediaUnitPacketizer.packetize(MirageMosaicMediaUnitPacketizerInput(
            streamID: 7,
            packetSequenceStart: 1000,
            timestamp: 5_000,
            tilePlanEpoch: 2,
            mediaEpoch: 3,
            mediaUnitIndex: 4,
            tileIndex: 5,
            transportGroupIndex: 6,
            presentationGroupIndex: 7,
            unitFrameNumber: 8,
            tileVersion: 9,
            dependencyVersion: 1,
            isKeyframe: true,
            isAtomicGroup: true,
            payload: payload,
            maximumPayloadBytes: 4
        ))

        #expect(packets.count == 3)
        for (index, packet) in packets.enumerated() {
            let header = try #require(MirageMosaicPacketHeader.deserialize(from: packet))
            let fragment = Data(packet.dropFirst(MirageWire.mirageMosaicHeaderSize))
            let expectedRangeStart = index * 4
            let expectedRangeEnd = min(expectedRangeStart + 4, payload.count)

            #expect(header.packetSequence == UInt32(1000 + index))
            #expect(header.fragmentIndex == UInt16(index))
            #expect(header.fragmentCount == 3)
            #expect(header.mediaUnitIndex == 4)
            #expect(header.tileIndex == 5)
            #expect(header.transportGroupIndex == 6)
            #expect(header.presentationGroupIndex == 7)
            #expect(header.unitByteCount == 10)
            #expect(header.flags.contains(.keyframe))
            #expect(header.flags.contains(.atomicGroup))
            #expect(header.flags.contains(.endOfUnit) == (index == 2))
            #expect(fragment == Data(payload[expectedRangeStart ..< expectedRangeEnd]))
            #expect(header.checksum == MirageWire.CRC32.calculate(fragment))
        }
    }
}
