//
//  StreamEncoderSettingsChangeMessageTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Stream Encoder Settings Change Message")
struct StreamEncoderSettingsChangeMessageTests {
    @Test("Older encoder settings messages decode without bitrate ceiling")
    func olderEncoderSettingsMessagesDecodeWithoutBitrateCeiling() throws {
        let data = Data(
            #"{"streamID":7,"colorDepth":"standard","bitrate":60000000,"streamScale":1.0,"targetFrameRate":60}"#.utf8
        )

        let message = try JSONDecoder().decode(StreamEncoderSettingsChangeMessage.self, from: data)

        #expect(message.streamID == 7)
        #expect(message.bitrate == 60_000_000)
        #expect(message.bitrateAdaptationCeiling == nil)
    }

    @Test("Encoder settings messages encode bitrate ceiling when present")
    func encoderSettingsMessagesEncodeBitrateCeilingWhenPresent() throws {
        let message = StreamEncoderSettingsChangeMessage(
            streamID: 9,
            bitrate: 64_000_000,
            bitrateAdaptationCeiling: 128_000_000
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(StreamEncoderSettingsChangeMessage.self, from: data)

        #expect(decoded.streamID == 9)
        #expect(decoded.bitrate == 64_000_000)
        #expect(decoded.bitrateAdaptationCeiling == 128_000_000)
    }
}
