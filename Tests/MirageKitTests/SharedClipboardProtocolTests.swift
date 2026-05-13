//
//  SharedClipboardProtocolTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKit
import Foundation
import Testing

extension SharedClipboardTests {
    @Test("Shared clipboard control types are recognized")
    func sharedClipboardControlTypeRegistration() {
        for type in [ControlMessageType.sharedClipboardStatus, .sharedClipboardUpdate] {
            var data = Data([type.rawValue])
            withUnsafeBytes(of: UInt32(0).littleEndian) { data.append(contentsOf: $0) }

            switch ControlMessage.deserialize(from: data) {
            case let .success(message, consumed):
                #expect(consumed == data.count)
                #expect(message.type == type)
            default:
                Issue.record("Expected \(type) to parse successfully.")
            }
        }
    }

    @Test("Shared clipboard messages serialize metadata and payload")
    func sharedClipboardMessageSerialization() throws {
        let statusEnvelope = try ControlMessage(
            type: .sharedClipboardStatus,
            content: SharedClipboardStatusMessage(enabled: true)
        )
        let (decodedStatusEnvelope, _) = try requireParsedControlMessage(from: statusEnvelope.serialize())
        let decodedStatus = try decodedStatusEnvelope.decode(SharedClipboardStatusMessage.self)
        #expect(decodedStatus.enabled)

        let representation = SharedClipboardRepresentation(
            kind: .file,
            contentType: "public.data",
            filename: "Support.txt",
            byteCount: 3
        )
        let updateEnvelope = try ControlMessage(
            type: .sharedClipboardUpdate,
            content: SharedClipboardUpdateMessage(
                changeID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                logicalVersion: 42,
                sentAtMs: 1_234_567,
                representation: representation,
                encryptedPayload: Data([0x01, 0x02, 0x03]),
                chunkIndex: 2,
                chunkCount: 5
            )
        )
        let (decodedUpdateEnvelope, _) = try requireParsedControlMessage(from: updateEnvelope.serialize())
        let decodedUpdate = try decodedUpdateEnvelope.decode(SharedClipboardUpdateMessage.self)
        #expect(decodedUpdate.logicalVersion == 42)
        #expect(decodedUpdate.sentAtMs == 1_234_567)
        #expect(decodedUpdate.representation == representation)
        #expect(decodedUpdate.encryptedPayload == Data([0x01, 0x02, 0x03]))
        #expect(decodedUpdate.chunkIndex == 2)
        #expect(decodedUpdate.chunkCount == 5)
    }

    @Test("Shared clipboard crypto round-trips binary payloads")
    func sharedClipboardCryptoRoundTrip() throws {
        let context = MirageMediaSecurityContext(
            sessionKey: Data(repeating: 0x4D, count: MirageMediaSecurity.sessionKeyLength)
        )
        let payload = Data([0x00, 0xFE, 0x7A])
        let encryptedPayload = try MirageMediaSecurity.encryptClipboardPayload(payload, context: context)
        let decryptedPayload = try MirageMediaSecurity.decryptClipboardPayload(encryptedPayload, context: context)
        #expect(decryptedPayload == payload)
    }

    @Test("Shared clipboard oversized and empty payloads are rejected")
    func sharedClipboardOversizeDropBehavior() {
        let oversized = Data(repeating: 0x61, count: MirageSharedClipboard.maximumBinaryPayloadBytes + 1)
        let maxText = Data(repeating: 0x61, count: MirageSharedClipboard.maximumTextPayloadBytes)
        let oversizedText = Data(repeating: 0x61, count: MirageSharedClipboard.maximumTextPayloadBytes + 1)
        let textRepresentation = SharedClipboardRepresentation(
            kind: .text,
            contentType: "public.utf8-plain-text",
            filename: nil,
            byteCount: maxText.count
        )
        let imageRepresentation = SharedClipboardRepresentation(
            kind: .image,
            contentType: "public.png",
            filename: nil,
            byteCount: oversized.count
        )

        #expect(MirageSharedClipboard.validatedPayload(maxText, representation: textRepresentation) == maxText)
        #expect(MirageSharedClipboard.validatedPayload(oversizedText, representation: textRepresentation) == nil)
        #expect(MirageSharedClipboard.validatedPayload(oversized, representation: imageRepresentation) == nil)
    }

    @Test("Shared clipboard chunks 256 KiB text payloads")
    func sharedClipboardChunksLargeTextPayloads() throws {
        let payload = Data(repeating: 0x61, count: MirageSharedClipboard.maximumTextPayloadBytes)
        let item = MirageSharedClipboardItem(
            representation: SharedClipboardRepresentation(
                kind: .text,
                contentType: "public.utf8-plain-text",
                filename: nil,
                byteCount: payload.count
            ),
            payload: payload
        )
        let localSend = MirageSharedClipboardLocalSend(
            item: item,
            orderingToken: MirageSharedClipboardOrderingToken(
                logicalVersion: 1,
                changeID: UUID(uuidString: "00000000-0000-0000-0000-00000000CAFE")!
            )
        )
        let context = MirageMediaSecurityContext(
            sessionKey: Data(repeating: 0x4D, count: MirageMediaSecurity.sessionKeyLength)
        )

        let messages = try MirageSharedClipboard.makeUpdateMessages(
            localSend: localSend,
            sentAtMs: 123,
            mediaSecurityContext: context
        )

        #expect(messages.count == MirageSharedClipboard.maximumTextPayloadBytes / MirageSharedClipboard.chunkSize)
    }
}
