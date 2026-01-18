import Testing
@testable import MirageKit

@Suite("MirageKit Tests")
struct MirageKitTests {
    @Test("Protocol header serialization")
    func testFrameHeaderSerialization() {
        let header = FrameHeader(
            flags: [.keyframe, .endOfFrame],
            streamID: 1,
            sequenceNumber: 100,
            timestamp: 123456789,
            frameNumber: 50,
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: 1024,
            checksum: 0xDEADBEEF
        )

        let data = header.serialize()
        #expect(data.count == MirageHeaderSize)

        let deserialized = FrameHeader.deserialize(from: data)
        #expect(deserialized != nil)
        #expect(deserialized?.streamID == 1)
        #expect(deserialized?.sequenceNumber == 100)
        #expect(deserialized?.frameNumber == 50)
        #expect(deserialized?.flags.contains(.keyframe) == true)
    }

    @Test("CRC32 calculation")
    func testCRC32() {
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
    func testControlMessageSerialization() throws {
        let hello = HelloMessage(
            deviceID: UUID(),
            deviceName: "Test Device",
            deviceType: .mac,
            protocolVersion: 1,
            capabilities: MirageHostCapabilities()
        )

        let message = try ControlMessage(type: .hello, content: hello)
        let data = message.serialize()

        let (deserialized, consumed) = ControlMessage.deserialize(from: data)!
        #expect(consumed == data.count)
        #expect(deserialized.type == .hello)

        let decodedHello = try deserialized.decode(HelloMessage.self)
        #expect(decodedHello.deviceName == "Test Device")
    }

    @Test("MirageWindow equality")
    func testWindowEquality() {
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
    func testCapabilitiesTXTRecord() {
        let capabilities = MirageHostCapabilities(
            maxStreams: 4,
            supportsHEVC: true,
            supportsP3ColorSpace: true,
            maxFrameRate: 120,
            protocolVersion: 1
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
    func testQualityPresets() {
        let ultra60 = MirageQualityPreset.ultra.encoderConfiguration(for: 60)
        let ultra120 = MirageQualityPreset.ultra.encoderConfiguration(for: 120)
        #expect(ultra60.maxBitrate == 200_000_000)
        #expect(ultra120.maxBitrate == 200_000_000)
        #expect(ultra120.keyframeQuality == 1.0)

        let medium60 = MirageQualityPreset.medium.encoderConfiguration(for: 60)
        let medium120 = MirageQualityPreset.medium.encoderConfiguration(for: 120)
        #expect(medium120.maxBitrate > medium60.maxBitrate)
        #expect(medium120.keyframeQuality < medium60.keyframeQuality)

        let low60 = MirageQualityPreset.low.encoderConfiguration(for: 60)
        let low120 = MirageQualityPreset.low.encoderConfiguration(for: 120)
        #expect(low120.maxBitrate <= low60.maxBitrate)
    }

    @Test("Stream statistics formatting")
    func testStatisticsFormatting() {
        let stats = MirageStreamStatistics(
            currentBitrate: 85_000_000,
            currentFrameRate: 120,
            processedFrames: 1000,
            droppedFrames: 5,
            averageLatencyMs: 25.5
        )

        #expect(stats.formattedBitrate == "85.0 Mbps")
        #expect(stats.formattedLatency == "25.5 ms")
        #expect(stats.dropRate < 0.01)
    }
}
