//
//  MirageWireCustomStreamingPayloadTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageMedia
import MirageWire
import Testing

@Suite("MirageWire Custom Streaming Payloads")
struct MirageWireCustomStreamingPayloadTests {
    @Test("Custom stream start request round-trips in wire target")
    func customStreamStartRequestRoundTripsInWireTarget() throws {
        let startupRequestID = try #require(UUID(uuidString: "77000000-0000-0000-0000-000000000004"))
        let request = MirageWire.StartCustomStreamMessage(
            startupRequestID: startupRequestID,
            kind: "dev.example.custom.v1",
            metadata: ["purpose": "test"],
            displayWidth: 0,
            displayHeight: -2,
            targetFrameRate: 500,
            streamScale: 0.5,
            mediaMaxPacketSize: 1_000
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .startCustomStream, content: request).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.StartCustomStreamMessage.self)

        #expect(decoded.startupRequestID == startupRequestID)
        #expect(decoded.kind == "dev.example.custom.v1")
        #expect(decoded.metadata == ["purpose": "test"])
        #expect(decoded.displayWidth == 1)
        #expect(decoded.displayHeight == 1)
        #expect(decoded.targetFrameRate == 120)
        #expect(decoded.streamScale == 0.5)
        #expect(decoded.mediaMaxPacketSize == 1_000)
        #expect(decoded.resolvedHostBufferingPolicy == .freshestFrame)
    }

    @Test("Custom stream started payload round-trips in wire target")
    func customStreamStartedPayloadRoundTripsInWireTarget() throws {
        let startupRequestID = try #require(UUID(uuidString: "77000000-0000-0000-0000-000000000001"))
        let startupAttemptID = try #require(UUID(uuidString: "77000000-0000-0000-0000-000000000002"))
        let descriptor = MirageMedia.MirageCustomStreamDescriptor(
            kind: "dev.example.custom.v1",
            displayName: "Example Custom Stream",
            metadata: ["purpose": "test"],
            defaultWidth: 1_024,
            defaultHeight: 768,
            defaultFrameRate: 60,
            supportsInput: true
        )
        let started = MirageWire.MirageCustomStreamStartedMessage(
            startupRequestID: startupRequestID,
            streamID: 42,
            descriptor: descriptor,
            width: 1_024,
            height: 768,
            frameRate: 60,
            codec: .h264,
            startupAttemptID: startupAttemptID,
            dimensionToken: 12,
            acceptedMediaMaxPacketSize: 1_200
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .customStreamStarted, content: started).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.MirageCustomStreamStartedMessage.self)

        #expect(decoded == started)
        #expect(decoded.descriptor == descriptor)
        #expect(decoded.codec == .h264)
        #expect(decoded.dimensionToken == 12)
    }

    @Test("Custom stream stop and stopped payloads round-trip in wire target")
    func customStreamStopAndStoppedPayloadsRoundTripInWireTarget() throws {
        let stopRequest = MirageWire.StopCustomStreamMessage(streamID: 42)
        let stopEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .stopCustomStream, content: stopRequest).serialize()
        ).message
        let decodedStop = try stopEnvelope.decode(MirageWire.StopCustomStreamMessage.self)

        #expect(decodedStop.streamID == 42)

        let stopped = MirageWire.MirageCustomStreamStoppedMessage(streamID: 42, reason: .sourceStopped)
        let stoppedEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .customStreamStopped, content: stopped).serialize()
        ).message
        let decodedStopped = try stoppedEnvelope.decode(MirageWire.MirageCustomStreamStoppedMessage.self)

        #expect(decodedStopped == stopped)
        #expect(decodedStopped.reason.rawValue == "sourceStopped")
    }

    @Test("Custom stream failure payload round-trips in wire target")
    func customStreamFailurePayloadRoundTripsInWireTarget() throws {
        let startupRequestID = try #require(UUID(uuidString: "77000000-0000-0000-0000-000000000003"))
        let failure = MirageWire.CustomStreamFailedMessage(
            startupRequestID: startupRequestID,
            reason: "No custom source registered"
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .customStreamFailed, content: failure).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.CustomStreamFailedMessage.self)

        #expect(decoded.startupRequestID == startupRequestID)
        #expect(decoded.reason == "No custom source registered")
    }
}
