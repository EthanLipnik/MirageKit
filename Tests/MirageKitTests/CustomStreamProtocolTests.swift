//
//  CustomStreamProtocolTests.swift
//  MirageKit
//
//  Created by Codex on 4/30/26.
//

@testable import MirageKit
import CoreVideo
import Testing

@Suite("Custom Stream Protocol")
struct CustomStreamProtocolTests {

    @Test("Custom stream control messages round-trip through control envelope")
    func customStreamMessagesRoundTrip() throws {
        let startupRequestID = UUID()
        let descriptor = MirageCustomStreamDescriptor(
            kind: "dev.example.custom.v1",
            displayName: "Example Custom Stream",
            metadata: ["purpose": "test"],
            defaultWidth: 1024,
            defaultHeight: 768,
            defaultFrameRate: 60,
            supportsInput: true
        )
        let startRequest = StartCustomStreamMessage(
            startupRequestID: startupRequestID,
            kind: descriptor.kind,
            metadata: ["scene": "primary"],
            displayWidth: 1024,
            displayHeight: 768,
            targetFrameRate: 60,
            scaleFactor: 2,
            streamScale: 1,
            mediaMaxPacketSize: 1200
        )
        let startEnvelope = try ControlMessage(type: .startCustomStream, content: startRequest)
        let (decodedStartEnvelope, _) = try requireParsedControlMessage(from: startEnvelope.serialize())
        let decodedStartRequest = try decodedStartEnvelope.decode(StartCustomStreamMessage.self)

        #expect(decodedStartEnvelope.type == .startCustomStream)
        #expect(decodedStartRequest.startupRequestID == startupRequestID)
        #expect(decodedStartRequest.kind == descriptor.kind)
        #expect(decodedStartRequest.metadata["scene"] == "primary")
        #expect(decodedStartRequest.publicRequest.requiredPixelFormat == kCVPixelFormatType_32BGRA)

        let started = MirageCustomStreamStartedMessage(
            startupRequestID: startupRequestID,
            streamID: 42,
            descriptor: descriptor,
            width: 1024,
            height: 768,
            frameRate: 60,
            codec: .h264,
            startupAttemptID: UUID(),
            dimensionToken: 12,
            acceptedMediaMaxPacketSize: 1200
        )
        let startedEnvelope = try ControlMessage(type: .customStreamStarted, content: started)
        let (decodedStartedEnvelope, _) = try requireParsedControlMessage(from: startedEnvelope.serialize())
        let decodedStarted = try decodedStartedEnvelope.decode(MirageCustomStreamStartedMessage.self)

        #expect(decodedStartedEnvelope.type == .customStreamStarted)
        #expect(decodedStarted == started)

        let stopped = MirageCustomStreamStoppedMessage(streamID: 42, reason: .clientRequested)
        let stoppedEnvelope = try ControlMessage(type: .customStreamStopped, content: stopped)
        let (decodedStoppedEnvelope, _) = try requireParsedControlMessage(from: stoppedEnvelope.serialize())
        let decodedStopped = try decodedStoppedEnvelope.decode(MirageCustomStreamStoppedMessage.self)

        #expect(decodedStoppedEnvelope.type == .customStreamStopped)
        #expect(decodedStopped == stopped)
    }
}
