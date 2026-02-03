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
            checksum: 0xDEAD_BEEF
        )

        let data = header.serialize()
        #expect(data.count == mirageHeaderSize)

        let deserialized = FrameHeader.deserialize(from: data)
        #expect(deserialized != nil)
        #expect(deserialized?.streamID == 1)
        #expect(deserialized?.sequenceNumber == 100)
        #expect(deserialized?.frameNumber == 50)
        #expect(deserialized?.flags.contains(.keyframe) == true)
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

    @Test("Quality presets")
    func qualityPresets() {
        let ultra60 = MirageQualityPreset.ultra.encoderConfiguration(for: 60)
        let ultra120 = MirageQualityPreset.ultra.encoderConfiguration(for: 120)
        #expect(ultra120.minBitrate == 200_000_000)
        #expect(ultra60.maxBitrate == 200_000_000)
        #expect(ultra120.minBitrate == ultra120.maxBitrate)
        #expect(ultra120.pixelFormat == .p010)

        let medium60 = MirageQualityPreset.medium.encoderConfiguration(for: 60)
        let medium120 = MirageQualityPreset.medium.encoderConfiguration(for: 120)
        #expect((medium120.minBitrate ?? 0) > (medium60.minBitrate ?? 0))
        #expect(medium120.pixelFormat == .p010)

        let low60 = MirageQualityPreset.low.encoderConfiguration(for: 60)
        let low120 = MirageQualityPreset.low.encoderConfiguration(for: 120)
        #expect((low120.minBitrate ?? 0) < (low60.minBitrate ?? 0))
        #expect((low120.minBitrate ?? 0) < (medium120.minBitrate ?? 0))
        #expect(low120.pixelFormat == .nv12)
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
