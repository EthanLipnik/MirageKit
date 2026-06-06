//
//  MirageWireBaselineFixturesTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

import CoreGraphics
import Foundation
@testable import MirageKit
import Testing
import MirageInput
import MirageWire

@Suite("Mirage Wire Baseline Fixtures")
struct MirageWireBaselineFixturesTests {
    @Test("Control message envelope baseline bytes")
    func controlMessageEnvelopeBaselineBytes() throws {
        let message = MirageWire.ControlMessage(type: .ping)
        let serialized = message.serialize()
        let expected = try data(hex: "0400000000")

        #expect(serialized == expected)

        let (decoded, consumed) = try requireParsedControlMessage(from: serialized)
        #expect(consumed == 5)
        #expect(decoded.type == .ping)
        #expect(decoded.payload.isEmpty)
    }

    @Test("MirageWire.FrameHeader baseline bytes")
    func frameHeaderBaselineBytes() throws {
        let header = MirageWire.FrameHeader(
            flags: [.keyframe, .endOfFrame, .desktopStream],
            streamID: 7,
            sequenceNumber: 0x0102_0304,
            timestamp: 0x0102_0304_0506_0708,
            frameNumber: 0x0A0B_0C0D,
            fragmentIndex: 2,
            fragmentCount: 5,
            fecBlockSize: 3,
            payloadLength: 0x0000_01F4,
            frameByteCount: 0x0000_1000,
            checksum: 0xAABB_CCDD,
            contentRect: CGRect(x: 1.5, y: 2.25, width: 640, height: 360.5),
            dimensionToken: 0x1234,
            epoch: 0x0056
        )
        let expected = try data(
            hex: """
            4752494dfcf90300030107000403020108070605040302010d0c0b0a0200050003f401000000100000ddccbbaa0000c03f00001040000020440040b44334125600
            """
        )

        #expect(header.serialize() == expected)
        #expect(MirageWire.FrameHeader.deserialize(from: expected)?.streamID == 7)
        #expect(MirageWire.FrameHeader.deserialize(from: expected)?.dimensionToken == 0x1234)
    }

    @Test("Binary input payload baseline bytes")
    func binaryInputPayloadBaselineBytes() throws {
        let input = MirageWire.InputEventMessage(
            streamID: 0x1234,
            event: .mouseDown(
                MirageInput.MirageMouseEvent(
                    button: .right,
                    location: CGPoint(x: 0.25, y: 0.5),
                    clickCount: 2,
                    modifiers: [.shift, .command],
                    pressure: 0.75,
                    timestamp: 1234.5
                )
            )
        )
        let payload = try input.serializePayload()
        let expectedPayload = try data(
            hex: """
            0134120501000000000000d03f000000000000e03f020000001200000000000000000000000000e83f0000000000004a9340
            """
        )

        #expect(payload == expectedPayload)

        let controlMessage = MirageWire.ControlMessage(type: .inputEvent, payload: payload)
        var expectedControlMessage = try data(hex: "3032000000")
        expectedControlMessage.append(expectedPayload)
        #expect(controlMessage.serialize() == expectedControlMessage)
    }

    @Test("Shared clipboard update baseline payload")
    func sharedClipboardUpdateBaselinePayload() throws {
        let changeID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let update = MirageWire.SharedClipboardUpdateMessage(
            changeID: changeID,
            logicalVersion: 42,
            sentAtMs: 1_700_000_000_123,
            representation: MirageWire.SharedClipboardRepresentation(
                kind: .text,
                contentType: "public.utf8-plain-text",
                filename: nil,
                byteCount: 5
            ),
            encryptedPayload: Data("hello".utf8),
            chunkIndex: 0,
            chunkCount: 1
        )
        let envelope = try MirageWire.ControlMessage(type: .sharedClipboardUpdate, content: update)
        let payload = try jsonDictionary(for: envelope.payload)
        let representation = payload["representation"] as? [String: Any]

        #expect((payload["chunkCount"] as? NSNumber)?.intValue == 1)
        #expect((payload["chunkIndex"] as? NSNumber)?.intValue == 0)
        #expect(payload["encryptedPayload"] as? String == "aGVsbG8=")
        #expect((payload["sentAtMs"] as? NSNumber)?.int64Value == 1_700_000_000_123)
        #expect((payload["logicalVersion"] as? NSNumber)?.intValue == 42)
        #expect(payload["changeID"] as? String == "00000000-0000-0000-0000-000000000123")
        #expect((representation?["byteCount"] as? NSNumber)?.intValue == 5)
        #expect(representation?["kind"] as? String == "text")
        #expect(representation?["contentType"] as? String == "public.utf8-plain-text")

        let (decodedEnvelope, consumed) = try requireParsedControlMessage(from: envelope.serialize())
        #expect(consumed == envelope.serialize().count)
        let decoded = try decodedEnvelope.decode(MirageWire.SharedClipboardUpdateMessage.self)
        #expect(decoded.changeID == changeID)
        #expect(decoded.logicalVersion == 42)
    }

    @Test("Current startup request field baselines")
    func currentStartupRequestFieldBaselines() throws {
        let appStartupID = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"))
        let appSessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000A2"))
        let appRequest = MirageWire.SelectAppMessage(
            startupRequestID: appStartupID,
            appSessionID: appSessionID,
            bundleIdentifier: "com.example.Editor",
            targetFrameRate: 90,
            scaleFactor: 2.0,
            displayWidth: 1920,
            displayHeight: 1200,
            keyFrameInterval: 1800,
            captureQueueDepth: 4,
            colorDepth: .pro,
            bitrate: 200_000_000,
            enteredBitrate: 220_000_000,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            allowRuntimeQualityAdjustment: false,
            allowEncoderCatchUpQualityAdjustment: true,
            lowLatencyHighResolutionCompressionBoost: true,
            disableResolutionCap: false,
            audioConfiguration: .default,
            maxConcurrentVisibleWindows: 3,
            sizePreset: .medium,
            mediaMaxPacketSize: 1400,
            clientTransportPathKind: .wifi,
            clientMediaPathProfile: .localWiFi,
            clientPathSignature: "status=satisfied|kind=wifi|media=localWiFi",
            clientPolicyPathKind: .vpn,
            clientPolicyMediaPathProfile: .vpnOrOverlay,
            codec: .hevc
        )
        let appFields = try jsonObject(for: .selectApp, content: appRequest)

        #expect(appFields["startupRequestID"] as? String == appStartupID.uuidString)
        #expect(appFields["appSessionID"] as? String == appSessionID.uuidString)
        #expect(appFields["bundleIdentifier"] as? String == "com.example.Editor")
        #expect((appFields["targetFrameRate"] as? NSNumber)?.intValue == 90)
        #expect((appFields["maxConcurrentVisibleWindows"] as? NSNumber)?.intValue == 3)
        #expect(appFields["latencyMode"] as? String == "lowestLatency")
        #expect(appFields["hostBufferingPolicy"] as? String == "freshestFrame")
        #expect(appFields["sizePreset"] as? String == "medium")
        #expect(appFields["codec"] as? String == "hvc1")

        let desktopStartupID = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000D1"))
        let geometryContractID = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000D2"))
        let desktopRequest = MirageWire.StartDesktopStreamMessage(
            startupRequestID: desktopStartupID,
            scaleFactor: 2.0,
            displayWidth: 3008,
            displayHeight: 1692,
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            captureQueueDepth: 6,
            colorDepth: .pro,
            mode: .unified,
            cursorPresentation: MirageWire.MirageDesktopCursorPresentation(
                source: .simulated,
                lockClientCursorWhenUsingMirageCursor: true,
                lockClientCursorWhenUsingHostCursor: false
            ),
            enteredBitrate: 180_000_000,
            bitrate: 150_000_000,
            latencyMode: .smoothest,
            hostBufferingPolicy: .stability,
            allowRuntimeQualityAdjustment: true,
            allowEncoderCatchUpQualityAdjustment: true,
            lowLatencyHighResolutionCompressionBoost: false,
            disableResolutionCap: true,
            streamScale: 0.875,
            audioConfiguration: .default,
            dataPort: 12_345,
            useHostResolution: false,
            mediaMaxPacketSize: 1200,
            clientTransportPathKind: .wired,
            clientMediaPathProfile: .wired,
            clientPathSignature: "status=satisfied|kind=wired|media=wired",
            clientPolicyPathKind: .vpn,
            clientPolicyMediaPathProfile: .vpnOrOverlay,
            desktopGeometryContractID: geometryContractID,
            desktopGeometrySceneIdentity: "scene-main",
            desktopGeometryDisplayPixelWidth: 3008,
            desktopGeometryDisplayPixelHeight: 1692,
            desktopGeometryEncodedPixelWidth: 2632,
            desktopGeometryEncodedPixelHeight: 1480,
            desktopGeometryRefreshTargetHz: 60
        )
        let desktopFields = try jsonObject(for: .startDesktopStream, content: desktopRequest)

        #expect(desktopFields["startupRequestID"] as? String == desktopStartupID.uuidString)
        #expect((desktopFields["displayWidth"] as? NSNumber)?.intValue == 3008)
        #expect((desktopFields["displayHeight"] as? NSNumber)?.intValue == 1692)
        #expect((desktopFields["targetFrameRate"] as? NSNumber)?.intValue == 60)
        #expect(desktopFields["mode"] as? String == "unified")
        let cursorPresentation = desktopFields["cursorPresentation"] as? [String: Any]
        #expect(cursorPresentation?["source"] as? String == "simulated")
        #expect(cursorPresentation?["lockClientCursorWhenUsingMirageCursor"] as? Bool == true)
        #expect(cursorPresentation?["lockClientCursorWhenUsingHostCursor"] as? Bool == false)
        #expect(desktopFields["desktopGeometryContractID"] as? String == geometryContractID.uuidString)
        #expect(desktopFields["desktopGeometrySceneIdentity"] as? String == "scene-main")
        #expect((desktopFields["desktopGeometryEncodedPixelWidth"] as? NSNumber)?.intValue == 2632)
        #expect((desktopFields["desktopGeometryRefreshTargetHz"] as? NSNumber)?.intValue == 60)
    }
}

private enum WireBaselineFixtureError: Error {
    case invalidHex
    case invalidJSONObject
}

private func data(hex: String) throws -> Data {
    let cleaned = hex.filter { !$0.isWhitespace }
    guard cleaned.count.isMultiple(of: 2) else {
        throw WireBaselineFixtureError.invalidHex
    }

    var bytes = Data()
    bytes.reserveCapacity(cleaned.count / 2)

    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index ..< next], radix: 16) else {
            throw WireBaselineFixtureError.invalidHex
        }
        bytes.append(byte)
        index = next
    }

    return bytes
}

private func jsonObject(for type: MirageWire.ControlMessageType, content: some Encodable) throws -> [String: Any] {
    let envelope = try MirageWire.ControlMessage(type: type, content: content)
    return try jsonDictionary(for: envelope.payload)
}

private func jsonDictionary(for data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw WireBaselineFixtureError.invalidJSONObject
    }
    return object
}
