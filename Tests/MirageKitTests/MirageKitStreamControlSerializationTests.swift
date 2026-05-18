//
//  MirageKitStreamControlSerializationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
@testable import MirageKit
import Testing

@Suite("MirageKit Stream Control Serialization")
struct MirageKitStreamControlSerializationTests {
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
            sampleRate: 48000,
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
        #expect(decoded?.sampleRate == 48000)
        #expect(decoded?.channelCount == 2)
        #expect(decoded?.checksum == 0xABCD_1234)
    }

    @Test("Stream encoder settings message serialization")
    func streamEncoderSettingsSerialization() throws {
        let request = StreamEncoderSettingsChangeMessage(
            streamID: 7,
            colorDepth: .pro,
            bitrate: 120_000_000,
            streamScale: 0.75,
            targetFrameRate: 30
        )

        let message = try ControlMessage(type: .streamEncoderSettingsChange, content: request)
        let serialized = message.serialize()
        let (decodedEnvelope, consumed) = try requireParsedControlMessage(from: serialized)
        #expect(consumed == serialized.count)
        #expect(decodedEnvelope.type == .streamEncoderSettingsChange)

        let decodedRequest = try decodedEnvelope.decode(StreamEncoderSettingsChangeMessage.self)
        #expect(decodedRequest.streamID == 7)
        #expect(decodedRequest.colorDepth == .pro)
        #expect(decodedRequest.bitrate == 120_000_000)
        #expect(decodedRequest.targetFrameRate == 30)
        let scale = try #require(decodedRequest.streamScale)
        #expect(abs(Double(scale) - 0.75) < 0.0001)
    }

    @Test("Start stream request latency mode serialization")
    func startStreamLatencyModeSerialization() throws {
        let request = StartStreamMessage(
            windowID: 9,
            targetFrameRate: 120,
            scaleFactor: 2.0,
            displayWidth: 1920,
            displayHeight: 1080,
            keyFrameInterval: 1800,
            captureQueueDepth: 6,
            colorDepth: .pro,
            bitrate: 150_000_000,
            latencyMode: .smoothest,
            hostBufferingPolicy: .stability,
            allowRuntimeQualityAdjustment: true,
            lowLatencyHighResolutionCompressionBoost: false,
            disableResolutionCap: true,
            streamScale: 1.0,
            audioConfiguration: .default
        )

        let envelope = try ControlMessage(type: .startStream, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StartStreamMessage.self)
        #expect(decoded.targetFrameRate == 120)
        #expect(decoded.latencyMode == .smoothest)
        #expect(decoded.hostBufferingPolicy == .stability)
        #expect(decoded.resolvedHostBufferingPolicy == .stability)
        #expect(decoded.colorDepth == .pro)
        #expect(decoded.bitrate == 150_000_000)
        #expect(decoded.lowLatencyHighResolutionCompressionBoost == false)
    }

    @Test("Select app request latency mode serialization")
    func selectAppLatencyModeSerialization() throws {
        let request = SelectAppMessage(
            bundleIdentifier: "com.example.Editor",
            targetFrameRate: 90,
            scaleFactor: 2.0,
            displayWidth: 1920,
            displayHeight: 1200,
            keyFrameInterval: 1800,
            captureQueueDepth: 4,
            colorDepth: .pro,
            bitrate: 200_000_000,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            allowRuntimeQualityAdjustment: false,
            lowLatencyHighResolutionCompressionBoost: true,
            disableResolutionCap: false,
            audioConfiguration: .default
        )

        let envelope = try ControlMessage(type: .selectApp, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(SelectAppMessage.self)
        #expect(decoded.targetFrameRate == 90)
        #expect(decoded.latencyMode == .lowestLatency)
        #expect(decoded.hostBufferingPolicy == .freshestFrame)
        #expect(decoded.resolvedHostBufferingPolicy == .freshestFrame)
        #expect(decoded.colorDepth == .pro)
        #expect(decoded.lowLatencyHighResolutionCompressionBoost == true)
    }

    @Test("Stream startup requests serialize media packet sizing")
    func streamStartupRequestsSerializeMediaPacketSizing() throws {
        let startStream = StartStreamMessage(
            windowID: 12,
            targetFrameRate: 60,
            mediaMaxPacketSize: 1400
        )
        let startStreamEnvelope = try ControlMessage(type: .startStream, content: startStream)
        let (decodedStartStreamEnvelope, _) = try requireParsedControlMessage(from: startStreamEnvelope.serialize())
        let decodedStartStream = try decodedStartStreamEnvelope.decode(StartStreamMessage.self)
        #expect(decodedStartStream.mediaMaxPacketSize == 1400)

        let selectApp = SelectAppMessage(
            bundleIdentifier: "com.example.Editor",
            targetFrameRate: 60,
            maxConcurrentVisibleWindows: 2,
            mediaMaxPacketSize: 1400
        )
        let selectAppEnvelope = try ControlMessage(type: .selectApp, content: selectApp)
        let (decodedSelectAppEnvelope, _) = try requireParsedControlMessage(from: selectAppEnvelope.serialize())
        let decodedSelectApp = try decodedSelectAppEnvelope.decode(SelectAppMessage.self)
        #expect(decodedSelectApp.mediaMaxPacketSize == 1400)

        let startDesktop = StartDesktopStreamMessage(
            scaleFactor: nil,
            displayWidth: 3008,
            displayHeight: 1692,
            targetFrameRate: 60,
            mediaMaxPacketSize: 1200
        )
        let startDesktopEnvelope = try ControlMessage(type: .startDesktopStream, content: startDesktop)
        let (decodedStartDesktopEnvelope, _) = try requireParsedControlMessage(from: startDesktopEnvelope.serialize())
        let decodedStartDesktop = try decodedStartDesktopEnvelope.decode(StartDesktopStreamMessage.self)
        #expect(decodedStartDesktop.mediaMaxPacketSize == 1200)
    }

    @Test("Stream startup requests default missing host buffering policy to stability")
    func streamStartupRequestsDefaultMissingHostBufferingPolicyToStability() throws {
        let startStreamEnvelope = try ControlMessage(
            type: .startStream,
            content: StartStreamMessage(windowID: 12, targetFrameRate: 60)
        )
        let (decodedStartStreamEnvelope, _) = try requireParsedControlMessage(from: startStreamEnvelope.serialize())
        let decodedStartStream = try decodedStartStreamEnvelope.decode(StartStreamMessage.self)
        #expect(decodedStartStream.hostBufferingPolicy == nil)
        #expect(decodedStartStream.resolvedHostBufferingPolicy == .stability)

        let selectAppEnvelope = try ControlMessage(
            type: .selectApp,
            content: SelectAppMessage(bundleIdentifier: "com.example.Editor", targetFrameRate: 60)
        )
        let (decodedSelectAppEnvelope, _) = try requireParsedControlMessage(from: selectAppEnvelope.serialize())
        let decodedSelectApp = try decodedSelectAppEnvelope.decode(SelectAppMessage.self)
        #expect(decodedSelectApp.hostBufferingPolicy == nil)
        #expect(decodedSelectApp.resolvedHostBufferingPolicy == .stability)

        let startDesktopEnvelope = try ControlMessage(
            type: .startDesktopStream,
            content: StartDesktopStreamMessage(
                scaleFactor: nil,
                displayWidth: 3008,
                displayHeight: 1692,
                targetFrameRate: 60
            )
        )
        let (decodedStartDesktopEnvelope, _) = try requireParsedControlMessage(from: startDesktopEnvelope.serialize())
        let decodedStartDesktop = try decodedStartDesktopEnvelope.decode(StartDesktopStreamMessage.self)
        #expect(decodedStartDesktop.hostBufferingPolicy == nil)
        #expect(decodedStartDesktop.resolvedHostBufferingPolicy == .stability)

        let customEnvelope = try ControlMessage(
            type: .startCustomStream,
            content: StartCustomStreamMessage(
                kind: "test",
                displayWidth: 1280,
                displayHeight: 720,
                targetFrameRate: 60
            )
        )
        let (decodedCustomEnvelope, _) = try requireParsedControlMessage(from: customEnvelope.serialize())
        let decodedCustom = try decodedCustomEnvelope.decode(StartCustomStreamMessage.self)
        #expect(decodedCustom.hostBufferingPolicy == nil)
        #expect(decodedCustom.resolvedHostBufferingPolicy == .stability)
    }

    @Test("Quality test and started messages serialize accepted media packet sizing")
    func qualityTestAndStartedMessagesSerializeMediaPacketSizing() throws {
        let qualityRequest = QualityTestRequestMessage(
            testID: UUID(),
            plan: MirageQualityTestPlan(stages: []),
            payloadBytes: 1188,
            mediaMaxPacketSize: 1400,
            stopAfterFirstBreach: true
        )
        let qualityEnvelope = try ControlMessage(type: .qualityTestRequest, content: qualityRequest)
        let (decodedQualityEnvelope, _) = try requireParsedControlMessage(from: qualityEnvelope.serialize())
        let decodedQualityRequest = try decodedQualityEnvelope.decode(QualityTestRequestMessage.self)
        #expect(decodedQualityRequest.mediaMaxPacketSize == 1400)
        #expect(decodedQualityRequest.stopAfterFirstBreach)

        let started = StreamStartedMessage(
            streamID: 42,
            windowID: 12,
            width: 1920,
            height: 1080,
            frameRate: 60,
            codec: .hevc,
            acceptedMediaMaxPacketSize: 1400
        )
        let startedEnvelope = try ControlMessage(type: .streamStarted, content: started)
        let (decodedStartedEnvelope, _) = try requireParsedControlMessage(from: startedEnvelope.serialize())
        let decodedStarted = try decodedStartedEnvelope.decode(StreamStartedMessage.self)
        #expect(decodedStarted.acceptedMediaMaxPacketSize == 1400)

        let desktopStarted = DesktopStreamStartedMessage(
            streamID: 77,
            desktopSessionID: UUID(),
            width: 3008,
            height: 1692,
            frameRate: 60,
            codec: .hevc,
            displayCount: 1,
            acceptedMediaMaxPacketSize: 1200
        )
        let desktopStartedEnvelope = try ControlMessage(type: .desktopStreamStarted, content: desktopStarted)
        let (decodedDesktopStartedEnvelope, _) = try requireParsedControlMessage(from: desktopStartedEnvelope.serialize())
        let decodedDesktopStarted = try decodedDesktopStartedEnvelope.decode(DesktopStreamStartedMessage.self)
        #expect(decodedDesktopStarted.acceptedMediaMaxPacketSize == 1200)
    }

    @Test("Desktop stream failed payload serialization")
    func desktopStreamFailedSerialization() throws {
        let payload = DesktopStreamFailedMessage(reason: "Virtual display failed activation")

        let envelope = try ControlMessage(type: .desktopStreamFailed, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(DesktopStreamFailedMessage.self)
        #expect(decoded.reason == "Virtual display failed activation")
    }

    @Test("Stop stream origin serialization")
    func stopStreamOriginSerialization() throws {
        let payload = StopStreamMessage(
            streamID: 55,
            minimizeWindow: false,
            origin: .clientWindowClosed
        )

        let envelope = try ControlMessage(type: .stopStream, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StopStreamMessage.self)
        #expect(decoded.streamID == 55)
        #expect(decoded.minimizeWindow == false)
        #expect(decoded.origin == .clientWindowClosed)
    }

    @Test("Start desktop request latency mode serialization")
    func startDesktopLatencyModeSerialization() throws {
        let request = StartDesktopStreamMessage(
            scaleFactor: 2.0,
            displayWidth: 3008,
            displayHeight: 1692,
            targetFrameRate: 120,
            keyFrameInterval: 1800,
            captureQueueDepth: 5,
            colorDepth: .pro,
            mode: .unified,
            bitrate: 500_000_000,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            allowRuntimeQualityAdjustment: false,
            lowLatencyHighResolutionCompressionBoost: false,
            disableResolutionCap: true,
            streamScale: 1.0,
            audioConfiguration: .default,
            dataPort: 63220
        )

        let envelope = try ControlMessage(type: .startDesktopStream, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StartDesktopStreamMessage.self)
        #expect(decoded.targetFrameRate == 120)
        #expect(decoded.latencyMode == .lowestLatency)
        #expect(decoded.hostBufferingPolicy == .freshestFrame)
        #expect(decoded.resolvedHostBufferingPolicy == .freshestFrame)
        #expect(decoded.displayWidth == 3008)
        #expect(decoded.displayHeight == 1692)
        #expect(decoded.colorDepth == .pro)
        #expect(decoded.lowLatencyHighResolutionCompressionBoost == false)
    }

    @Test("Start desktop request cursor presentation serialization")
    func startDesktopCursorPresentationSerialization() throws {
        let request = StartDesktopStreamMessage(
            scaleFactor: 2.0,
            displayWidth: 3008,
            displayHeight: 1692,
            targetFrameRate: 60,
            mode: .secondary,
            cursorPresentation: MirageDesktopCursorPresentation(
                source: .host,
                lockClientCursorWhenUsingMirageCursor: true,
                lockClientCursorWhenUsingHostCursor: false
            ),
            audioConfiguration: .default,
            dataPort: 63220
        )

        let envelope = try ControlMessage(type: .startDesktopStream, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(StartDesktopStreamMessage.self)
        #expect(decoded.cursorPresentation?.source == .host)
        #expect(decoded.cursorPresentation?.lockClientCursorWhenUsingMirageCursor == true)
        #expect(decoded.cursorPresentation?.lockClientCursorWhenUsingHostCursor == false)
    }
}
