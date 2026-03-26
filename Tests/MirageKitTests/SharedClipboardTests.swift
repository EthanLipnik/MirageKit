//
//  SharedClipboardTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Shared Clipboard")
struct SharedClipboardTests {
    @Test("Shared clipboard feature is advertised")
    func sharedClipboardFeatureRegistration() {
        #expect(MirageFeatureSet.sharedClipboardV1.rawValue == (1 << 5))
        #expect(mirageSupportedFeatures.contains(.sharedClipboardV1))
    }

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

    @Test("Shared clipboard messages serialize")
    func sharedClipboardMessageSerialization() throws {
        let statusEnvelope = try ControlMessage(
            type: .sharedClipboardStatus,
            content: SharedClipboardStatusMessage(enabled: true)
        )
        let (decodedStatusEnvelope, _) = try requireParsedControlMessage(from: statusEnvelope.serialize())
        let decodedStatus = try decodedStatusEnvelope.decode(SharedClipboardStatusMessage.self)
        #expect(decodedStatus.enabled)

        let updateEnvelope = try ControlMessage(
            type: .sharedClipboardUpdate,
            content: SharedClipboardUpdateMessage(
                changeID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                sentAtMs: 1_234_567,
                encryptedText: Data([0x01, 0x02, 0x03]),
                chunkIndex: 2,
                chunkCount: 5
            )
        )
        let (decodedUpdateEnvelope, _) = try requireParsedControlMessage(from: updateEnvelope.serialize())
        let decodedUpdate = try decodedUpdateEnvelope.decode(SharedClipboardUpdateMessage.self)
        #expect(decodedUpdate.sentAtMs == 1_234_567)
        #expect(decodedUpdate.encryptedText == Data([0x01, 0x02, 0x03]))
        #expect(decodedUpdate.chunkIndex == 2)
        #expect(decodedUpdate.chunkCount == 5)
    }

    @Test("Shared clipboard messages default to single chunk")
    func sharedClipboardMessageDefaultChunk() throws {
        let update = SharedClipboardUpdateMessage(
            changeID: UUID(),
            sentAtMs: 100,
            encryptedText: Data([0xFF])
        )
        #expect(update.chunkIndex == 0)
        #expect(update.chunkCount == 1)
    }

    @Test("Shared clipboard crypto round-trips")
    func sharedClipboardCryptoRoundTrip() throws {
        let context = MirageMediaSecurityContext(
            sessionKey: Data(repeating: 0x4D, count: MirageMediaSecurity.sessionKeyLength),
            udpRegistrationToken: Data(repeating: 0x52, count: MirageMediaSecurity.registrationTokenLength)
        )
        let plaintext = "Mirage clipboard round-trip"
        let encrypted = try MirageMediaSecurity.encryptClipboardText(plaintext, context: context)
        let decrypted = try MirageMediaSecurity.decryptClipboardText(encrypted, context: context)
        #expect(decrypted == plaintext)
    }

    @Test("Shared clipboard oversized and empty text are rejected")
    func sharedClipboardOversizeDropBehavior() {
        let oversized = String(repeating: "a", count: MirageSharedClipboard.maximumTextBytes + 1)
        #expect(MirageSharedClipboard.validatedText(nil) == nil)
        #expect(MirageSharedClipboard.validatedText("") == nil)
        #expect(MirageSharedClipboard.validatedText(oversized) == nil)
        #expect(MirageSharedClipboard.validatedText("clipboard") == "clipboard")
    }

    @Test("Initial observation sends current text")
    func initialObservationSendsText() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 5)
        #expect(state.observeInitialText("hello", changeCount: 5) == .send("hello"))
    }

    @Test("Initial observation ignores nil and empty text")
    func initialObservationIgnoresNilEmpty() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 5)
        #expect(state.observeInitialText(nil, changeCount: 5) == .ignore)

        state.activate(changeCount: 6)
        #expect(state.observeInitialText("", changeCount: 6) == .ignore)
    }

    @Test("Initial observation ignores when inactive")
    func initialObservationIgnoresInactive() {
        var state = MirageSharedClipboardState()
        #expect(state.observeInitialText("hello", changeCount: 5) == .ignore)
    }

    @Test("After initial observation, same changeCount is ignored by regular observeLocalText")
    func initialObservationUpdatesChangeCount() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 5)
        #expect(state.observeInitialText("hello", changeCount: 5) == .send("hello"))
        #expect(state.observeLocalText("hello", changeCount: 5) == .ignore)
        #expect(state.observeLocalText("updated", changeCount: 6) == .send("updated"))
    }

    @Test("Initial observation followed by remote write and echo suppression")
    func initialObservationThenRemoteEcho() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 5)
        #expect(state.observeInitialText("local", changeCount: 5) == .send("local"))

        state.recordRemoteWrite(text: "remote", changeCount: 6)
        #expect(state.observeLocalText("remote", changeCount: 6) == .ignore)
        #expect(state.pendingRemoteText == nil)
        #expect(state.observeLocalText("new-local", changeCount: 7) == .send("new-local"))
    }

    @Test("Shared clipboard uses changes-only activation baseline and suppresses remote echo once")
    func sharedClipboardStateMachine() {
        var state = MirageSharedClipboardState()

        state.activate(changeCount: 7)
        #expect(state.observeLocalText("existing", changeCount: 7) == .ignore)
        #expect(state.observeLocalText("fresh", changeCount: 8) == .send("fresh"))

        state.recordRemoteWrite(text: "remote", changeCount: 9)
        #expect(state.observeLocalText("remote", changeCount: 9) == .ignore)
        #expect(state.observeLocalText("remote", changeCount: 10) == .send("remote"))
    }

    // MARK: - Chunk Text

    @Test("chunkText returns single chunk for small text")
    func chunkTextSmall() {
        let text = "Hello, world!"
        let chunks = MirageSharedClipboard.chunkText(text)
        #expect(chunks.count == 1)
        #expect(chunks[0] == text)
    }

    @Test("chunkText splits large text into multiple chunks")
    func chunkTextLarge() {
        let text = String(repeating: "a", count: 10_000)
        let chunks = MirageSharedClipboard.chunkText(text)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == text)
        for chunk in chunks {
            #expect(chunk.utf8.count <= MirageSharedClipboard.chunkSize)
        }
    }

    @Test("chunkText preserves multi-byte characters at boundaries")
    func chunkTextMultiByte() {
        // Each emoji is 4 bytes UTF-8. Fill just over one chunk with emojis.
        let emoji = "\u{1F600}" // 4 bytes
        let count = (MirageSharedClipboard.chunkSize / 4) + 10
        let text = String(repeating: emoji, count: count)
        let chunks = MirageSharedClipboard.chunkText(text)
        #expect(chunks.count >= 2)
        #expect(chunks.joined() == text)
    }

    // MARK: - Chunk Buffer

    @Test("Chunk buffer returns text immediately for single chunk")
    func chunkBufferSingleChunk() {
        var buffer = MirageSharedClipboardChunkBuffer()
        let id = UUID()
        let result = buffer.addChunk(changeID: id, chunkIndex: 0, chunkCount: 1, text: "hello")
        #expect(result == "hello")
    }

    @Test("Chunk buffer reassembles multiple chunks in order")
    func chunkBufferMultipleChunks() {
        var buffer = MirageSharedClipboardChunkBuffer()
        let id = UUID()
        #expect(buffer.addChunk(changeID: id, chunkIndex: 0, chunkCount: 3, text: "aaa") == nil)
        #expect(buffer.addChunk(changeID: id, chunkIndex: 2, chunkCount: 3, text: "ccc") == nil)
        let result = buffer.addChunk(changeID: id, chunkIndex: 1, chunkCount: 3, text: "bbb")
        #expect(result == "aaabbbccc")
    }

    @Test("Chunk buffer handles interleaved transfers")
    func chunkBufferInterleaved() {
        var buffer = MirageSharedClipboardChunkBuffer()
        let id1 = UUID()
        let id2 = UUID()
        #expect(buffer.addChunk(changeID: id1, chunkIndex: 0, chunkCount: 2, text: "A") == nil)
        #expect(buffer.addChunk(changeID: id2, chunkIndex: 0, chunkCount: 2, text: "X") == nil)
        #expect(buffer.addChunk(changeID: id1, chunkIndex: 1, chunkCount: 2, text: "B") == "AB")
        #expect(buffer.addChunk(changeID: id2, chunkIndex: 1, chunkCount: 2, text: "Y") == "XY")
    }
}
