//
//  MirageKitTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

@testable import MirageKit
import Testing

@Suite("MirageKit Tests")
struct MirageKitTests {
    @Test("Protocol header serialization")
    func frameHeaderSerialization() {
        let header = FrameHeader(
            flags: [.keyframe, .endOfFrame],
            streamID: 1,
            sequenceNumber: 100,
            timestamp: 123_456_789,
            frameNumber: 50,
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: 1024,
            frameByteCount: 1024,
            checksum: 0xDEAD_BEEF
        )

        let data = header.serialize()
        #expect(data.count == mirageHeaderSize)

        let deserialized = FrameHeader.deserialize(from: data)
        #expect(deserialized != nil)
        #expect(deserialized?.streamID == 1)
        #expect(deserialized?.sequenceNumber == 100)
        #expect(deserialized?.frameNumber == 50)
        #expect(deserialized?.flags.contains(FrameFlags.keyframe) == true)
    }

    @Test("CRC32 calculation")
    func cRC32() {
        let data = Data("Hello, World!".utf8)
        let crc = CRC32.calculate(data)
        #expect(crc != 0)

        // Same data should produce same CRC
        let crc2 = CRC32.calculate(data)
        #expect(crc == crc2)

        // Different data should produce different CRC
        let data2 = Data("Hello, MirageKit!".utf8)
        let crc3 = CRC32.calculate(data2)
        #expect(crc != crc3)
    }

    @Test("Control message serialization")
    func controlMessageSerialization() throws {
        let hello = HelloMessage(
            deviceID: UUID(),
            deviceName: "Test Device",
            deviceType: .mac,
            protocolVersion: Int(MirageKit.protocolVersion),
            capabilities: MirageHostCapabilities()
        )

        let message = try ControlMessage(type: .hello, content: hello)
        let data = message.serialize()

        let (deserialized, consumed) = try #require(ControlMessage.deserialize(from: data))
        #expect(consumed == data.count)
        #expect(deserialized.type == .hello)

        let decodedHello = try deserialized.decode(HelloMessage.self)
        #expect(decodedHello.deviceName == "Test Device")
    }

    @Test("Stream encoder settings message serialization")
    func streamEncoderSettingsSerialization() throws {
        let request = StreamEncoderSettingsChangeMessage(
            streamID: 7,
            pixelFormat: .nv12,
            colorSpace: .displayP3,
            bitrate: 120_000_000,
            streamScale: 0.75
        )

        let message = try ControlMessage(type: .streamEncoderSettingsChange, content: request)
        let serialized = message.serialize()
        let (decodedEnvelope, consumed) = try #require(ControlMessage.deserialize(from: serialized))
        #expect(consumed == serialized.count)
        #expect(decodedEnvelope.type == .streamEncoderSettingsChange)

        let decodedRequest = try decodedEnvelope.decode(StreamEncoderSettingsChangeMessage.self)
        #expect(decodedRequest.streamID == 7)
        #expect(decodedRequest.pixelFormat == .nv12)
        #expect(decodedRequest.colorSpace == .displayP3)
        #expect(decodedRequest.bitrate == 120_000_000)
        let scale = try #require(decodedRequest.streamScale)
        #expect(abs(Double(scale) - 0.75) < 0.0001)
    }

    @Test("MirageWindow equality")
    func windowEquality() {
        let window1 = MirageWindow(
            id: 1,
            title: "Test Window",
            application: nil,
            frame: .zero,
            isOnScreen: true,
            windowLayer: 0
        )

        let window2 = MirageWindow(
            id: 1,
            title: "Test Window",
            application: nil,
            frame: .zero,
            isOnScreen: true,
            windowLayer: 0
        )

        #expect(window1 == window2)
        #expect(window1.hashValue == window2.hashValue)
    }

    @Test("Host capabilities TXT record")
    func capabilitiesTXTRecord() {
        let capabilities = MirageHostCapabilities(
            maxStreams: 4,
            supportsHEVC: true,
            supportsP3ColorSpace: true,
            maxFrameRate: 120,
            protocolVersion: Int(MirageKit.protocolVersion)
        )

        let txtRecord = capabilities.toTXTRecord()
        #expect(txtRecord["maxStreams"] == "4")
        #expect(txtRecord["hevc"] == "1")
        #expect(txtRecord["p3"] == "1")
        #expect(txtRecord["maxFps"] == "120")

        let decoded = MirageHostCapabilities.from(txtRecord: txtRecord)
        #expect(decoded.maxStreams == 4)
        #expect(decoded.supportsHEVC == true)
        #expect(decoded.maxFrameRate == 120)
    }

    @Test("Stream statistics formatting")
    func statisticsFormatting() {
        let stats = MirageStreamStatistics(
            currentFrameRate: 120,
            processedFrames: 1000,
            droppedFrames: 5,
            averageLatencyMs: 25.5
        )

        #expect(stats.formattedLatency == "25.5 ms")
        #expect(stats.dropRate < 0.01)
    }
}
