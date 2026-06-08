//
//  MirageClientFastPathStateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/18/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing
import MirageCore

@Suite("Client Fast Path State")
struct MirageClientFastPathStateTests {
    @Test("Early video packets are buffered until stream context registration")
    func earlyVideoPacketsAreBufferedUntilStreamContextRegistration() {
        let state = MirageClientFastPathState()
        let streamID: StreamID = 42
        let packet = Data([1, 2, 3, 4])

        #expect(state.videoPacketContext(for: streamID) == nil)
        #expect(state.bufferEarlyVideoPacket(packet, for: streamID))
        #expect(!state.bufferEarlyVideoPacket(Data([5]), for: streamID))

        state.addActiveStreamID(streamID)

        #expect(state.takeBufferedEarlyVideoPacket(for: streamID) == packet)
        #expect(state.takeBufferedEarlyVideoPacket(for: streamID) == nil)
    }

    @Test("Mosaic startup buffer deduplicates and retains complete grid")
    func mosaicStartupBufferDeduplicatesAndRetainsCompleteGrid() {
        let state = MirageClientFastPathState()
        let streamID: StreamID = 43
        state.addActiveStreamID(streamID)

        for mediaUnitIndex in UInt16(0) ..< UInt16(9) {
            #expect(state.bufferMosaicUnit(
                Self.mosaicUnit(mediaUnitIndex: mediaUnitIndex),
                for: streamID
            ))
        }
        #expect(state.bufferedMosaicUnitCount(for: streamID) == 9)

        #expect(state.bufferMosaicUnit(
            Self.mosaicUnit(mediaUnitIndex: 0, payload: Data([0xFF])),
            for: streamID
        ))
        #expect(state.bufferedMosaicUnitCount(for: streamID) == 9)

        let units = state.takeBufferedMosaicUnits(for: streamID)
        #expect(units.map(\.mediaUnitIndex) == Array(UInt16(0) ..< UInt16(9)))
        #expect(units.first?.payload == Data([0xFF]))
        #expect(state.bufferedMosaicUnitCount(for: streamID) == 0)
    }

    private static func mosaicUnit(
        mediaUnitIndex: UInt16,
        payload: Data = Data([0x01])
    ) -> StreamControllerMosaicMediaUnitReassembler.CompletedUnit {
        StreamControllerMosaicMediaUnitReassembler.CompletedUnit(
            streamID: 43,
            timestamp: 1,
            tilePlanEpoch: 2,
            mediaEpoch: 3,
            mediaUnitIndex: mediaUnitIndex,
            tileIndex: mediaUnitIndex,
            transportGroupIndex: 0,
            presentationGroupIndex: 0,
            unitFrameNumber: 4,
            tileVersion: UInt32(mediaUnitIndex) + 1,
            dependencyVersion: UInt32(mediaUnitIndex),
            isKeyframe: true,
            isAtomicGroup: true,
            payload: payload
        )
    }
}
