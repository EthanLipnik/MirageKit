//
//  CustomStreamProtocolTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/30/26.
//

@testable import MirageKit
import CoreVideo
import Foundation
import Testing
import MirageMedia
import MirageWire

@Suite("Custom Stream Protocol")
struct CustomStreamProtocolTests {
    @Test("Custom stream control messages round-trip through control envelope")
    func customStreamMessagesRoundTrip() throws {
        let startupRequestID = UUID()
        let descriptor = MirageMedia.MirageCustomStreamDescriptor(
            kind: "dev.example.custom.v1",
            displayName: "Example Custom Stream",
            metadata: ["purpose": "test"],
            defaultWidth: 1024,
            defaultHeight: 768,
            defaultFrameRate: 60,
            supportsInput: true
        )
        let startRequest = MirageWire.StartCustomStreamMessage(
            startupRequestID: startupRequestID,
            kind: descriptor.kind,
            metadata: ["scene": "primary"],
            displayWidth: 1024,
            displayHeight: 768,
            targetFrameRate: 60,
            streamScale: 1,
            mediaMaxPacketSize: 1200
        )
        let startEnvelope = try MirageWire.ControlMessage(type: .startCustomStream, content: startRequest)
        let (decodedStartEnvelope, _) = try requireParsedControlMessage(from: startEnvelope.serialize())
        let decodedStartRequest = try decodedStartEnvelope.decode(MirageWire.StartCustomStreamMessage.self)

        #expect(decodedStartEnvelope.type == .startCustomStream)
        #expect(decodedStartRequest.startupRequestID == startupRequestID)
        #expect(decodedStartRequest.kind == descriptor.kind)
        #expect(decodedStartRequest.metadata["scene"] == "primary")
        #expect(decodedStartRequest.publicRequest.requiredPixelFormat == kCVPixelFormatType_32BGRA)

        let started = MirageWire.MirageCustomStreamStartedMessage(
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
        let startedEnvelope = try MirageWire.ControlMessage(type: .customStreamStarted, content: started)
        let (decodedStartedEnvelope, _) = try requireParsedControlMessage(from: startedEnvelope.serialize())
        let decodedStarted = try decodedStartedEnvelope.decode(MirageWire.MirageCustomStreamStartedMessage.self)

        #expect(decodedStartedEnvelope.type == .customStreamStarted)
        #expect(decodedStarted == started)

        let stopped = MirageWire.MirageCustomStreamStoppedMessage(streamID: 42, reason: .clientRequested)
        let stoppedEnvelope = try MirageWire.ControlMessage(type: .customStreamStopped, content: stopped)
        let (decodedStoppedEnvelope, _) = try requireParsedControlMessage(from: stoppedEnvelope.serialize())
        let decodedStopped = try decodedStoppedEnvelope.decode(MirageWire.MirageCustomStreamStoppedMessage.self)

        #expect(decodedStoppedEnvelope.type == .customStreamStopped)
        #expect(decodedStopped == stopped)
    }
}
