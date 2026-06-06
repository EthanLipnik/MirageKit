//
//  MirageWireDesktopStreamingPayloadTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import Foundation
import MirageMedia
import MirageWire
import Testing

@Suite("MirageWire Desktop Streaming Payloads")
struct MirageWireDesktopStreamingPayloadTests {
    @Test("Desktop start request round-trips in wire target")
    func desktopStartRequestRoundTripsInWireTarget() throws {
        let startupRequestID = try #require(UUID(uuidString: "76000000-0000-0000-0000-000000000004"))
        let contractID = try #require(UUID(uuidString: "76000000-0000-0000-0000-000000000005"))
        let request = MirageWire.StartDesktopStreamMessage(
            startupRequestID: startupRequestID,
            scaleFactor: 2,
            displayWidth: 1_376,
            displayHeight: 1_032,
            targetFrameRate: 120,
            keyFrameInterval: 240,
            captureQueueDepth: 5,
            colorDepth: .ultra,
            mode: .secondary,
            cursorPresentation: MirageWire.MirageDesktopCursorPresentation(
                source: .host,
                lockClientCursorWhenUsingMirageCursor: false,
                lockClientCursorWhenUsingHostCursor: true
            ),
            enteredBitrate: 45_000_000,
            bitrate: 40_000_000,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            allowRuntimeQualityAdjustment: true,
            allowEncoderCatchUpQualityAdjustment: false,
            lowLatencyHighResolutionCompressionBoost: true,
            disableResolutionCap: false,
            streamScale: 0.75,
            audioConfiguration: .default,
            dataPort: 4_242,
            useHostResolution: false,
            mediaMaxPacketSize: 1_180,
            desktopGeometryContractID: contractID,
            desktopGeometrySceneIdentity: "scene-a",
            desktopGeometryDisplayPixelWidth: 2_752,
            desktopGeometryDisplayPixelHeight: 2_064,
            desktopGeometryEncodedPixelWidth: 2_752,
            desktopGeometryEncodedPixelHeight: 2_064,
            desktopGeometryRefreshTargetHz: 120
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .startDesktopStream, content: request).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.StartDesktopStreamMessage.self)

        #expect(decoded.startupRequestID == startupRequestID)
        #expect(decoded.scaleFactor == 2)
        #expect(decoded.displayWidth == 1_376)
        #expect(decoded.displayHeight == 1_032)
        #expect(decoded.targetFrameRate == 120)
        #expect(decoded.colorDepth == .ultra)
        #expect(decoded.mode == .secondary)
        #expect(decoded.cursorPresentation?.source == .host)
        #expect(decoded.latencyMode == .lowestLatency)
        #expect(decoded.resolvedHostBufferingPolicy == .freshestFrame)
        #expect(decoded.audioConfiguration == .default)
        #expect(decoded.dataPort == 4_242)
        #expect(decoded.mediaMaxPacketSize == 1_180)
        #expect(decoded.desktopGeometryContractID == contractID)
        #expect(decoded.desktopGeometryRefreshTargetHz == 120)
    }

    @Test("Desktop started payload round-trips transition metadata in wire target")
    func desktopStartedPayloadRoundTripsTransitionMetadataInWireTarget() throws {
        let desktopSessionID = try #require(UUID(uuidString: "76000000-0000-0000-0000-000000000006"))
        let startupAttemptID = try #require(UUID(uuidString: "76000000-0000-0000-0000-000000000007"))
        let transitionID = try #require(UUID(uuidString: "76000000-0000-0000-0000-000000000008"))
        let contractID = try #require(UUID(uuidString: "76000000-0000-0000-0000-000000000009"))
        let started = MirageWire.DesktopStreamStartedMessage(
            streamID: 42,
            desktopSessionID: desktopSessionID,
            width: 2_752,
            height: 2_064,
            frameRate: 120,
            codec: .hevc,
            startupAttemptID: startupAttemptID,
            displayCount: 2,
            dimensionToken: 18,
            acceptedMediaMaxPacketSize: 1_180,
            transitionID: transitionID,
            transitionPhase: .resize,
            transitionOutcome: .resized,
            desktopPresentationGeneration: 7,
            captureSource: .mainDisplayFallback,
            allowsClientResize: false,
            acceptedDisplayScaleFactor: 2,
            presentationWidth: 1_376,
            presentationHeight: 1_032,
            desktopGeometryContractID: contractID,
            desktopGeometrySceneIdentity: "scene-a",
            desktopGeometryDisplayPixelWidth: 2_752,
            desktopGeometryDisplayPixelHeight: 2_064,
            desktopGeometryEncodedPixelWidth: 2_752,
            desktopGeometryEncodedPixelHeight: 2_064,
            desktopGeometryRefreshTargetHz: 120,
            presentationRole: .appStreamPlaceholder,
            associatedAppSessionID: desktopSessionID,
            associatedAppStartupRequestID: startupAttemptID,
            associatedBundleIdentifier: "com.apple.mail"
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .desktopStreamStarted, content: started).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.DesktopStreamStartedMessage.self)

        #expect(decoded.streamID == 42)
        #expect(decoded.desktopSessionID == desktopSessionID)
        #expect(decoded.codec == .hevc)
        #expect(decoded.transitionPhase == .resize)
        #expect(decoded.transitionOutcome == .resized)
        #expect(decoded.captureSource == .mainDisplayFallback)
        #expect(decoded.presentationRole == .appStreamPlaceholder)
        #expect(decoded.associatedBundleIdentifier == "com.apple.mail")
        #expect(decoded.presentationSize == CGSize(width: 1_376, height: 1_032))
        #expect(decoded.streamReadyDesktopGeometryContract?.contractID == contractID)
        #expect(decoded.streamReadyDesktopGeometryContract?.refreshTargetHz == 120)
    }

    @Test("Desktop cursor presentation change payload round-trips in wire target")
    func desktopCursorPresentationChangePayloadRoundTripsInWireTarget() throws {
        let presentation = MirageWire.MirageDesktopCursorPresentation(
            source: .host,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: true
        )
        let request = MirageWire.DesktopCursorPresentationChangeMessage(
            streamID: 42,
            cursorPresentation: presentation
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .desktopCursorPresentationChange, content: request).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.DesktopCursorPresentationChangeMessage.self)

        #expect(decoded.streamID == 42)
        #expect(decoded.cursorPresentation == presentation)
        #expect(decoded.cursorPresentation.capturesHostCursor)
    }

    @Test("Stream setup cancellation payload round-trips in wire target")
    func streamSetupCancellationPayloadRoundTripsInWireTarget() throws {
        let startupRequestID = try #require(UUID(uuidString: "76000000-0000-0000-0000-000000000001"))
        let appSessionID = try #require(UUID(uuidString: "76000000-0000-0000-0000-000000000002"))
        let request = MirageWire.CancelStreamSetupMessage(
            startupRequestID: startupRequestID,
            kind: .app,
            appSessionID: appSessionID
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .cancelStreamSetup, content: request).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.CancelStreamSetupMessage.self)

        #expect(decoded.startupRequestID == startupRequestID)
        #expect(decoded.kind == .app)
        #expect(decoded.appSessionID == appSessionID)
    }

    @Test("Desktop stop and stopped payloads round-trip in wire target")
    func desktopStopAndStoppedPayloadsRoundTripInWireTarget() throws {
        let desktopSessionID = try #require(UUID(uuidString: "76000000-0000-0000-0000-000000000003"))
        let stopRequest = MirageWire.StopDesktopStreamMessage(
            streamID: 33,
            desktopSessionID: desktopSessionID
        )
        let stopEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .stopDesktopStream, content: stopRequest).serialize()
        ).message
        let decodedStop = try stopEnvelope.decode(MirageWire.StopDesktopStreamMessage.self)

        #expect(decodedStop.streamID == 33)
        #expect(decodedStop.desktopSessionID == desktopSessionID)

        let stopped = MirageWire.DesktopStreamStoppedMessage(
            streamID: 33,
            desktopSessionID: desktopSessionID,
            reason: .clientRequested
        )
        let stoppedEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .desktopStreamStopped, content: stopped).serialize()
        ).message
        let decodedStopped = try stoppedEnvelope.decode(MirageWire.DesktopStreamStoppedMessage.self)

        #expect(decodedStopped.streamID == 33)
        #expect(decodedStopped.desktopSessionID == desktopSessionID)
        #expect(decodedStopped.reason == .clientRequested)
    }

    @Test("Desktop failure payload round-trips in wire target")
    func desktopFailurePayloadRoundTripsInWireTarget() throws {
        let failure = MirageWire.DesktopStreamFailedMessage(reason: "Virtual display failed activation")
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .desktopStreamFailed, content: failure).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.DesktopStreamFailedMessage.self)

        #expect(decoded.reason == "Virtual display failed activation")
        #expect(MirageWire.DesktopStreamStopReason.hostShutdown.rawValue == "hostShutdown")
    }
}
