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
            capabilities: MirageHostCapabilities(),
            negotiation: MirageProtocolNegotiation.clientHello(
                protocolVersion: Int(MirageKit.protocolVersion),
                supportedFeatures: mirageSupportedFeatures
            ),
            identity: MirageIdentityEnvelope(
                keyID: "test-key-id",
                publicKey: Data([0x01, 0x02]),
                timestampMs: 1_234,
                nonce: "nonce",
                signature: Data([0x03, 0x04])
            )
        )

        let message = try ControlMessage(type: .hello, content: hello)
        let data = message.serialize()

        let (deserialized, consumed) = try #require(ControlMessage.deserialize(from: data))
        #expect(consumed == data.count)
        #expect(deserialized.type == ControlMessageType.hello)

        let decodedHello = try deserialized.decode(HelloMessage.self)
        #expect(decodedHello.deviceName == "Test Device")
    }

    @Test("Hello message optional mismatch update flag serialization")
    func helloOptionalMismatchUpdateFlagSerialization() throws {
        let hello = HelloMessage(
            deviceID: UUID(),
            deviceName: "Mismatch Test",
            deviceType: .iPad,
            protocolVersion: Int(MirageKit.protocolVersion),
            capabilities: MirageHostCapabilities(),
            negotiation: MirageProtocolNegotiation.clientHello(
                protocolVersion: Int(MirageKit.protocolVersion),
                supportedFeatures: mirageSupportedFeatures
            ),
            identity: MirageIdentityEnvelope(
                keyID: "test-key-id",
                publicKey: Data([0x01, 0x02]),
                timestampMs: 9_999,
                nonce: "nonce",
                signature: Data([0x03, 0x04])
            ),
            requestHostUpdateOnProtocolMismatch: true
        )

        let message = try ControlMessage(type: .hello, content: hello)
        let (decodedEnvelope, _) = try #require(ControlMessage.deserialize(from: message.serialize()))
        let decodedHello = try decodedEnvelope.decode(HelloMessage.self)
        #expect(decodedHello.requestHostUpdateOnProtocolMismatch == true)
    }

    @Test("Hello response mismatch metadata serialization")
    func helloResponseMismatchMetadataSerialization() throws {
        let response = HelloResponseMessage(
            accepted: false,
            hostID: UUID(),
            hostName: "Host",
            requiresAuth: false,
            dataPort: 9848,
            negotiation: MirageProtocolNegotiation.clientHello(
                protocolVersion: Int(MirageKit.protocolVersion),
                supportedFeatures: mirageSupportedFeatures
            ),
            requestNonce: "request-nonce",
            mediaEncryptionEnabled: false,
            udpRegistrationToken: Data(),
            identity: MirageIdentityEnvelope(
                keyID: "host-key-id",
                publicKey: Data([0x10, 0x20]),
                timestampMs: 10_000,
                nonce: "host-nonce",
                signature: Data([0x30, 0x40])
            ),
            rejectionReason: .protocolVersionMismatch,
            protocolMismatchHostVersion: 1,
            protocolMismatchClientVersion: 2,
            protocolMismatchUpdateTriggerAccepted: true,
            protocolMismatchUpdateTriggerMessage: "Update accepted"
        )

        let envelope = try ControlMessage(type: .helloResponse, content: response)
        let (decodedEnvelope, _) = try #require(ControlMessage.deserialize(from: envelope.serialize()))
        let decoded = try decodedEnvelope.decode(HelloResponseMessage.self)
        #expect(decoded.rejectionReason == .protocolVersionMismatch)
        #expect(decoded.protocolMismatchHostVersion == 1)
        #expect(decoded.protocolMismatchClientVersion == 2)
        #expect(decoded.protocolMismatchUpdateTriggerAccepted == true)
        #expect(decoded.protocolMismatchUpdateTriggerMessage == "Update accepted")
    }

    @Test("Audio control message serialization")
    func audioControlMessageSerialization() throws {
        let started = AudioStreamStartedMessage(
            streamID: 42,
            codec: .aacLC,
            sampleRate: 48_000,
            channelCount: 2
        )
        let startedEnvelope = try ControlMessage(type: .audioStreamStarted, content: started)
        let (decodedStartedEnvelope, _) = try #require(ControlMessage.deserialize(from: startedEnvelope.serialize()))
        #expect(decodedStartedEnvelope.type == .audioStreamStarted)
        let decodedStarted = try decodedStartedEnvelope.decode(AudioStreamStartedMessage.self)
        #expect(decodedStarted == started)

        let stopped = AudioStreamStoppedMessage(streamID: 42, reason: .sourceStopped)
        let stoppedEnvelope = try ControlMessage(type: .audioStreamStopped, content: stopped)
        let (decodedStoppedEnvelope, _) = try #require(ControlMessage.deserialize(from: stoppedEnvelope.serialize()))
        #expect(decodedStoppedEnvelope.type == .audioStreamStopped)
        let decodedStopped = try decodedStoppedEnvelope.decode(AudioStreamStoppedMessage.self)
        #expect(decodedStopped == stopped)
    }

    @Test("Host software update control message serialization")
    func hostSoftwareUpdateControlMessageSerialization() throws {
        let statusRequest = HostSoftwareUpdateStatusRequestMessage(forceRefresh: true)
        let requestEnvelope = try ControlMessage(type: .hostSoftwareUpdateStatusRequest, content: statusRequest)
        let (decodedRequestEnvelope, _) = try #require(ControlMessage.deserialize(from: requestEnvelope.serialize()))
        let decodedStatusRequest = try decodedRequestEnvelope.decode(HostSoftwareUpdateStatusRequestMessage.self)
        #expect(decodedStatusRequest.forceRefresh == true)

        let status = HostSoftwareUpdateStatusMessage(
            isSparkleAvailable: true,
            isCheckingForUpdates: false,
            isInstallInProgress: true,
            channel: .nightly,
            currentVersion: "1.2.0",
            availableVersion: "1.3.0",
            availableVersionTitle: "Mirage 1.3",
            lastCheckedAtMs: 1_700_000_000_000
        )
        let statusEnvelope = try ControlMessage(type: .hostSoftwareUpdateStatus, content: status)
        let (decodedStatusEnvelope, _) = try #require(ControlMessage.deserialize(from: statusEnvelope.serialize()))
        let decodedStatus = try decodedStatusEnvelope.decode(HostSoftwareUpdateStatusMessage.self)
        #expect(decodedStatus.channel == .nightly)
        #expect(decodedStatus.availableVersion == "1.3.0")
        #expect(decodedStatus.isInstallInProgress == true)

        let installRequest = HostSoftwareUpdateInstallRequestMessage(trigger: .protocolMismatch)
        let installRequestEnvelope = try ControlMessage(type: .hostSoftwareUpdateInstallRequest, content: installRequest)
        let (decodedInstallRequestEnvelope, _) = try #require(ControlMessage.deserialize(from: installRequestEnvelope.serialize()))
        let decodedInstallRequest = try decodedInstallRequestEnvelope.decode(HostSoftwareUpdateInstallRequestMessage.self)
        #expect(decodedInstallRequest.trigger == .protocolMismatch)

        let installResult = HostSoftwareUpdateInstallResultMessage(
            accepted: false,
            message: "Denied",
            status: status
        )
        let installResultEnvelope = try ControlMessage(type: .hostSoftwareUpdateInstallResult, content: installResult)
        let (decodedInstallResultEnvelope, _) = try #require(ControlMessage.deserialize(from: installResultEnvelope.serialize()))
        let decodedInstallResult = try decodedInstallResultEnvelope.decode(HostSoftwareUpdateInstallResultMessage.self)
        #expect(decodedInstallResult.accepted == false)
        #expect(decodedInstallResult.status?.currentVersion == "1.2.0")
        #expect(decodedInstallResult.message == "Denied")
    }

    @Test("Audio packet header serialization")
    func audioPacketHeaderSerialization() {
        let header = AudioPacketHeader(
            codec: .pcm16LE,
            flags: [.discontinuity],
            streamID: 7,
            sequenceNumber: 12,
            timestamp: 987_654_321,
            frameNumber: 33,
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: 256,
            frameByteCount: 256,
            sampleRate: 44_100,
            channelCount: 2,
            samplesPerFrame: 512,
            checksum: 0xABCD_1234
        )

        let serialized = header.serialize()
        #expect(serialized.count == mirageAudioHeaderSize)
        let decoded = AudioPacketHeader.deserialize(from: serialized)
        #expect(decoded != nil)
        #expect(decoded?.codec == .pcm16LE)
        #expect(decoded?.flags.contains(.discontinuity) == true)
        #expect(decoded?.streamID == 7)
        #expect(decoded?.sampleRate == 44_100)
        #expect(decoded?.channelCount == 2)
        #expect(decoded?.checksum == 0xABCD_1234)
    }

    @Test("Stream encoder settings message serialization")
    func streamEncoderSettingsSerialization() throws {
        let request = StreamEncoderSettingsChangeMessage(
            streamID: 7,
            bitDepth: .tenBit,
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
        #expect(decodedRequest.bitDepth == .tenBit)
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
        #expect(decoded.protocolVersion == Int(MirageKit.protocolVersion))
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
