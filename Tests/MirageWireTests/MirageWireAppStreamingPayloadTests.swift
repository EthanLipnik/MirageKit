//
//  MirageWireAppStreamingPayloadTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageMedia
import MirageWire
import Testing

@Suite("MirageWire App Streaming Payloads")
struct MirageWireAppStreamingPayloadTests {
    @Test("App start request round-trips in wire target")
    func appStartRequestRoundTripsInWireTarget() throws {
        let startupRequestID = try #require(UUID(uuidString: "75000000-0000-0000-0000-000000000004"))
        let appSessionID = try #require(UUID(uuidString: "75000000-0000-0000-0000-000000000005"))
        let request = MirageWire.SelectAppMessage(
            startupRequestID: startupRequestID,
            appSessionID: appSessionID,
            bundleIdentifier: "com.apple.mail",
            targetFrameRate: 120,
            scaleFactor: 2,
            displayWidth: 1_376,
            displayHeight: 1_032,
            keyFrameInterval: 240,
            captureQueueDepth: 5,
            colorDepth: .ultra,
            bitrate: 40_000_000,
            enteredBitrate: 45_000_000,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            allowRuntimeQualityAdjustment: true,
            allowEncoderCatchUpQualityAdjustment: false,
            lowLatencyHighResolutionCompressionBoost: true,
            disableResolutionCap: false,
            audioConfiguration: .default,
            maxConcurrentVisibleWindows: 0,
            sizePreset: .large,
            mediaMaxPacketSize: 1_180,
            codec: .hevc
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .selectApp, content: request).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.SelectAppMessage.self)

        #expect(decoded.startupRequestID == startupRequestID)
        #expect(decoded.appSessionID == appSessionID)
        #expect(decoded.bundleIdentifier == "com.apple.mail")
        #expect(decoded.targetFrameRate == 120)
        #expect(decoded.colorDepth == .ultra)
        #expect(decoded.latencyMode == .lowestLatency)
        #expect(decoded.resolvedHostBufferingPolicy == .freshestFrame)
        #expect(decoded.maxConcurrentVisibleWindows == 1)
        #expect(decoded.sizePreset == .large)
        #expect(decoded.mediaMaxPacketSize == 1_180)
        #expect(decoded.codec == .hevc)
    }

    @Test("Stream policy update sorts and clamps policies in wire target")
    func streamPolicyUpdateSortsAndClampsPoliciesInWireTarget() throws {
        let update = MirageWire.StreamPolicyUpdateMessage(
            epoch: 9,
            policies: [
                MirageWire.MirageStreamPolicy(
                    streamID: 42,
                    tier: .activeLive,
                    targetFPS: 240,
                    targetBitrateBps: 120_000_000
                ),
                MirageWire.MirageStreamPolicy(
                    streamID: 7,
                    tier: .passiveSnapshot,
                    targetFPS: 0,
                    targetBitrateBps: nil
                ),
            ]
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .streamPolicyUpdate, content: update).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.StreamPolicyUpdateMessage.self)

        #expect(decoded.epoch == 9)
        #expect(decoded.policies.map(\.streamID) == [7, 42])
        #expect(decoded.policies[0].tier == .passiveSnapshot)
        #expect(decoded.policies[0].targetFPS == 1)
        #expect(decoded.policies[1].tier == .activeLive)
        #expect(decoded.policies[1].targetFPS == 120)
        #expect(decoded.policies[1].targetBitrateBps == 120_000_000)
    }

    @Test("App atlas media update payload round-trips in wire target")
    func appAtlasMediaUpdatePayloadRoundTripsInWireTarget() throws {
        let startupAttemptID = try #require(UUID(uuidString: "75000000-0000-0000-0000-000000000001"))
        let region = MirageMedia.MirageAppAtlasRegion(
            windowID: 9_001,
            x: 128,
            y: 64,
            width: 1_440,
            height: 900,
            zIndex: 2,
            isFocused: true
        )
        let layout = MirageMedia.MirageAppAtlasLayout(
            mediaStreamID: 41,
            layoutEpoch: 7,
            width: 4_096,
            height: 2_304,
            regions: [region]
        )
        let update = MirageWire.AppAtlasMediaUpdateMessage(
            mediaStreamID: 41,
            width: 4_096,
            height: 2_304,
            codec: .hevc,
            frameRate: 120,
            dimensionToken: 12,
            layoutEpoch: 7,
            acceptedPacketSize: 1_180,
            layout: layout,
            startupAttemptID: startupAttemptID
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appAtlasMediaUpdate, content: update).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.AppAtlasMediaUpdateMessage.self)

        #expect(decoded.mediaStreamID == 41)
        #expect(decoded.width == 4_096)
        #expect(decoded.height == 2_304)
        #expect(decoded.codec == .hevc)
        #expect(decoded.frameRate == 120)
        #expect(decoded.dimensionToken == 12)
        #expect(decoded.layoutEpoch == 7)
        #expect(decoded.acceptedPacketSize == 1_180)
        #expect(decoded.layout == layout)
        #expect(decoded.startupAttemptID == startupAttemptID)
    }

    @Test("App stream started payload round-trips in wire target")
    func appStreamStartedPayloadRoundTripsInWireTarget() throws {
        let appSessionID = try #require(UUID(uuidString: "75000000-0000-0000-0000-000000000002"))
        let startupRequestID = try #require(UUID(uuidString: "75000000-0000-0000-0000-000000000003"))
        let region = MirageMedia.MirageAppAtlasRegion(
            windowID: 9_001,
            x: 32,
            y: 48,
            width: 1_440,
            height: 900,
            zIndex: 1
        )
        let layout = MirageMedia.MirageAppAtlasLayout(
            mediaStreamID: 41,
            layoutEpoch: 3,
            width: 2_048,
            height: 1_536,
            regions: [region]
        )
        let window = MirageWire.AppStreamStartedMessage.AppStreamWindow(
            streamID: 141,
            mediaStreamID: 41,
            windowID: 9_001,
            title: "Inbox",
            width: 1_440,
            height: 900,
            isResizable: true,
            atlasRegion: region
        )
        let started = MirageWire.AppStreamStartedMessage(
            appSessionID: appSessionID,
            startupRequestID: startupRequestID,
            bundleIdentifier: "com.apple.mail",
            appName: "Mail",
            windows: [window],
            atlasLayouts: [layout]
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appStreamStarted, content: started).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.AppStreamStartedMessage.self)
        let decodedWindow = try #require(decoded.windows.first)

        #expect(decoded.appSessionID == appSessionID)
        #expect(decoded.startupRequestID == startupRequestID)
        #expect(decoded.bundleIdentifier == "com.apple.mail")
        #expect(decoded.appName == "Mail")
        #expect(decodedWindow.streamID == 141)
        #expect(decodedWindow.mediaStreamID == 41)
        #expect(decodedWindow.windowID == 9_001)
        #expect(decodedWindow.atlasRegion == region)
        #expect(decoded.atlasLayouts == [layout])

        let encodedWindow = try JSONEncoder().encode(decodedWindow)
        let object = try #require(JSONSerialization.jsonObject(with: encodedWindow) as? [String: Any])
        #expect((object["streamID"] as? NSNumber)?.uint64Value == 141)
        #expect((object["mediaStreamID"] as? NSNumber)?.uint64Value == 41)
    }
}
