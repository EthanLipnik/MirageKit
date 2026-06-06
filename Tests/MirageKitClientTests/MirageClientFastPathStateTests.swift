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
}
