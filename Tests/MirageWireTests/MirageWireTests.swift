//
//  MirageWireTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import Foundation
import MirageWire
import Testing

@Suite("MirageWire")
struct MirageWireTests {
    @Test("Current Mirage protocol versions remain stable and named by boundary")
    func currentMirageProtocolVersionsRemainStableAndNamedByBoundary() {
        #expect(MirageWireProtocol.preRearchitectureCompatibilityVersion == 260604)
        #expect(MirageWireProtocol.rearchitectureCutoverVersion == 260605)
        #expect(
            MirageWireProtocol.rearchitectureCutoverVersion >
                MirageWireProtocol.preRearchitectureCompatibilityVersion
        )
        #expect(MirageWireProtocol.currentDiscoveryVersion == 260604)
        #expect(MirageWireProtocol.currentControlVersion == 260604)
        #expect(MirageWireProtocol.currentMediaPacketVersion == 260604)
        #expect(MirageWireProtocol.currentControlVersion == MirageWireProtocol.preRearchitectureCompatibilityVersion)
        #expect(
            MirageWireProtocol.currentMediaPacketVersion ==
                MirageWireProtocol.preRearchitectureCompatibilityVersion
        )
    }

    @Test("Video packet header keeps fixed wire bytes")
    func videoPacketHeaderKeepsFixedWireBytes() throws {
        let header = MirageWire.FrameHeader(
            flags: [.keyframe, .endOfFrame, .desktopStream],
            streamID: 7,
            sequenceNumber: 0x0102_0304,
            timestamp: 0x0102_0304_0506_0708,
            frameNumber: 0x0A0B_0C0D,
            fragmentIndex: 2,
            fragmentCount: 5,
            fecBlockSize: 3,
            payloadLength: 0x0000_01F4,
            frameByteCount: 0x0000_1000,
            checksum: 0xAABB_CCDD,
            contentRect: CGRect(x: 1.5, y: 2.25, width: 640, height: 360.5),
            dimensionToken: 0x1234,
            epoch: 0x0056
        )
        let expected = try data(
            hex: """
            4752494dfcf90300030107000403020108070605040302010d0c0b0a0200050003f401000000100000ddccbbaa0000c03f00001040000020440040b44334125600
            """
        )

        #expect(MirageWire.mirageHeaderSize == expected.count)
        #expect(header.serialize() == expected)
        #expect(MirageWire.FrameHeader.deserialize(from: expected)?.streamID == 7)
        #expect(MirageWire.FrameHeader.deserialize(from: expected)?.dimensionToken == 0x1234)
    }

    @Test("Audio packet header keeps fixed wire bytes")
    func audioPacketHeaderKeepsFixedWireBytes() throws {
        let header = MirageWire.AudioPacketHeader(
            codec: .aacLC,
            flags: [.discontinuity],
            streamID: 0x0009,
            sequenceNumber: 0x0102_0304,
            timestamp: 0x0102_0304_0506_0708,
            frameNumber: 0x0A0B_0C0D,
            fragmentIndex: 1,
            fragmentCount: 2,
            payloadLength: 0x0100,
            frameByteCount: 0x0000_0200,
            sampleRate: 48_000,
            channelCount: 2,
            samplesPerFrame: 960,
            checksum: 0xABCD_1234
        )
        let expected = try data(
            hex: """
            4152494dfcf9030001010009000403020108070605040302010d0c0b0a0100020000010002000080bb000002c0033412cdab
            """
        )

        #expect(MirageWire.mirageAudioHeaderSize == expected.count)
        #expect(header.serialize() == expected)
        #expect(MirageWire.AudioPacketHeader.deserialize(from: expected)?.streamID == 0x0009)
        #expect(MirageWire.AudioPacketHeader.deserialize(from: expected)?.checksum == 0xABCD_1234)
    }

    @Test("MirageWire.CRC32 keeps packet checksum contract")
    func crc32KeepsPacketChecksumContract() {
        let payload = Data("123456789".utf8)
        #expect(MirageWire.CRC32.calculate(payload) == 0xCBF4_3926)
    }

    @Test("Control message envelope keeps fixed wire bytes")
    func controlMessageEnvelopeKeepsFixedWireBytes() throws {
        let message = MirageWire.ControlMessage(type: .ping)
        let serialized = message.serialize()
        let expected = try data(hex: "0400000000")

        #expect(serialized == expected)

        guard case let .success(decoded, consumed) = MirageWire.ControlMessage.deserialize(from: expected) else {
            Issue.record("Expected control message to parse")
            return
        }
        #expect(consumed == 5)
        #expect(decoded.type == .ping)
        #expect(decoded.payload.isEmpty)
    }

    @Test("Control message parser reports partial and invalid frames")
    func controlMessageParserReportsPartialAndInvalidFrames() {
        guard case .needMoreData = MirageWire.ControlMessage.deserialize(from: Data([MirageWire.ControlMessageType.ping.rawValue])) else {
            Issue.record("Expected partial control frame to request more data")
            return
        }

        let unknownType = Data([0xEE, 0, 0, 0, 0])
        guard case let .invalidFrame(reason) = MirageWire.ControlMessage.deserialize(from: unknownType) else {
            Issue.record("Expected unknown control type to be rejected")
            return
        }
        #expect(reason.contains("Unknown control message type byte"))
    }

    @Test("Control message parser applies per-type payload limits")
    func controlMessageParserAppliesPerTypePayloadLimits() {
        let excessiveInlineAssetLength = MirageControlMessageLimits.maxInlineAssetPayloadBytes + 1
        let frame = controlFrame(
            type: .hostWallpaper,
            declaredPayloadLength: UInt32(excessiveInlineAssetLength)
        )

        guard case let .invalidFrame(reason) = MirageWire.ControlMessage.deserialize(from: frame) else {
            Issue.record("Expected oversized inline asset frame to be rejected")
            return
        }
        #expect(reason.contains("Control payload exceeds limit for hostWallpaper"))
    }

    @Test("Control message limits own receive buffering policy")
    func controlMessageLimitsOwnReceiveBufferingPolicy() {
        #expect(MirageControlMessageLimits.maxPayloadBytes == 8 * 1024 * 1024)
        #expect(MirageControlMessageLimits.maxLargeMetadataPayloadBytes == 32 * 1024 * 1024)
        #expect(MirageControlMessageLimits.maxInlineAssetPayloadBytes == 4 * 1024 * 1024)
        #expect(MirageControlMessageLimits.maxReceiveBufferBytes == 64 * 1024 * 1024)
        #expect(MirageControlMessageLimits.maxFrameBytes == MirageControlMessageLimits.maxLargeMetadataPayloadBytes + 5)
    }
}
