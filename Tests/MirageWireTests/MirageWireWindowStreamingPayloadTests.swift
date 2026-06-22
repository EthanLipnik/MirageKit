//
//  MirageWireWindowStreamingPayloadTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import Foundation
import MirageMedia
import MirageWire
import Testing

@Suite("MirageWire Window Streaming Payloads")
struct MirageWireWindowStreamingPayloadTests {
    @Test("Window start request round-trips in wire target")
    func windowStartRequestRoundTripsInWireTarget() throws {
        let request = MirageWire.StartStreamMessage(
            windowID: 9_001,
            targetFrameRate: 60,
            scaleFactor: 2,
            displayWidth: 1_440,
            displayHeight: 900,
            keyFrameInterval: 120,
            captureQueueDepth: 4,
            colorDepth: .pro,
            bitrate: 20_000_000,
            latencyMode: .smoothest,
            hostBufferingPolicy: .stability,
            allowRuntimeQualityAdjustment: true,
            lowLatencyHighResolutionCompressionBoost: false,
            disableResolutionCap: true,
            streamScale: 0.75,
            audioConfiguration: .default,
            mediaMaxPacketSize: 1_200,
            codec: .hevc
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .startStream, content: request).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.StartStreamMessage.self)

        #expect(decoded.windowID == 9_001)
        #expect(decoded.targetFrameRate == 60)
        #expect(decoded.scaleFactor == 2)
        #expect(decoded.displayWidth == 1_440)
        #expect(decoded.displayHeight == 900)
        #expect(decoded.colorDepth == .pro)
        #expect(decoded.latencyMode == .smoothest)
        #expect(decoded.resolvedHostBufferingPolicy == .stability)
        #expect(decoded.audioConfiguration == .default)
        #expect(decoded.mediaMaxPacketSize == 1_200)
        #expect(decoded.codec == .hevc)
    }

    @Test("Window inventory payloads round-trip in wire target")
    func windowInventoryPayloadsRoundTripInWireTarget() throws {
        let window = MirageMedia.MirageWindow(
            id: 9_001,
            title: "Inbox",
            application: MirageMedia.MirageApplication(
                id: 501,
                bundleIdentifier: "com.apple.mail",
                name: "Mail"
            ),
            frame: CGRect(x: 10, y: 20, width: 1_440, height: 900),
            isOnScreen: true,
            windowLayer: 0
        )
        let list = MirageWire.WindowListMessage(windows: [window])
        let listEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .windowList, content: list).serialize()
        ).message
        let decodedList = try listEnvelope.decode(MirageWire.WindowListMessage.self)

        #expect(decodedList.windows.first == window)
        #expect(decodedList.windows.first?.displayName == "Inbox")

        let updatedWindow = window.withTabCount(2)
        let update = MirageWire.WindowUpdateMessage(
            added: [window],
            removed: [9_002],
            updated: [updatedWindow]
        )
        let updateEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .windowUpdate, content: update).serialize()
        ).message
        let decodedUpdate = try updateEnvelope.decode(MirageWire.WindowUpdateMessage.self)

        #expect(decodedUpdate.added.first == window)
        #expect(decodedUpdate.removed == [9_002])
        #expect(decodedUpdate.updated.first?.tabCount == 2)
    }

    @Test("Window stop payload round-trips in wire target")
    func windowStopPayloadRoundTripsInWireTarget() throws {
        let stop = MirageWire.StopStreamMessage(
            streamID: 55,
            minimizeWindow: false,
            origin: .clientWindowClosed
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .stopStream, content: stop).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.StopStreamMessage.self)

        #expect(decoded.streamID == 55)
        #expect(decoded.minimizeWindow == false)
        #expect(decoded.origin == .clientWindowClosed)
    }

    @Test("Window started payload round-trips in wire target")
    func windowStartedPayloadRoundTripsInWireTarget() throws {
        let startupAttemptID = try #require(UUID(uuidString: "78000000-0000-0000-0000-000000000001"))
        let started = MirageWire.StreamStartedMessage(
            streamID: 42,
            windowID: 12,
            width: 1_920,
            height: 1_080,
            frameRate: 60,
            codec: .hevc,
            startupAttemptID: startupAttemptID,
            minWidth: 800,
            minHeight: 600,
            dimensionToken: 18,
            acceptedMediaMaxPacketSize: 1_400
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .streamStarted, content: started).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.StreamStartedMessage.self)

        #expect(decoded.streamID == 42)
        #expect(decoded.windowID == 12)
        #expect(decoded.width == 1_920)
        #expect(decoded.height == 1_080)
        #expect(decoded.frameRate == 60)
        #expect(decoded.codec == .hevc)
        #expect(decoded.startupAttemptID == startupAttemptID)
        #expect(decoded.minWidth == 800)
        #expect(decoded.minHeight == 600)
        #expect(decoded.dimensionToken == 18)
        #expect(decoded.acceptedMediaMaxPacketSize == 1_400)
    }

    @Test("Stream readiness payload round-trips desktop geometry contract in wire target")
    func streamReadinessPayloadRoundTripsDesktopGeometryContractInWireTarget() throws {
        let contractID = try #require(UUID(uuidString: "78000000-0000-0000-0000-000000000002"))
        let startupAttemptID = try #require(UUID(uuidString: "78000000-0000-0000-0000-000000000003"))
        let contract = MirageWire.StreamReadyDesktopGeometryContract(
            contractID: contractID,
            sceneIdentity: "",
            logicalWidth: 1_376,
            logicalHeight: 1_032,
            displayPixelWidth: 2_752,
            displayPixelHeight: 2_064,
            encodedPixelWidth: 2_752,
            encodedPixelHeight: 2_064,
            refreshTargetHz: 0
        )
        let ready = MirageWire.StreamReadyMessage(
            streamID: 42,
            startupAttemptID: startupAttemptID,
            kind: .desktop,
            desktopGeometryContract: contract
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .streamReady, content: ready).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.StreamReadyMessage.self)

        #expect(decoded.streamID == 42)
        #expect(decoded.startupAttemptID == startupAttemptID)
        #expect(decoded.kind == .desktop)
        #expect(decoded.desktopGeometryContract?.contractID == contractID)
        #expect(decoded.desktopGeometryContract?.sceneIdentity == nil)
        #expect(decoded.desktopGeometryContract?.refreshTargetHz == 1)
    }
}
