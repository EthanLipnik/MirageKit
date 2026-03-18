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
                encryptedText: Data([0x01, 0x02, 0x03])
            )
        )
        let (decodedUpdateEnvelope, _) = try requireParsedControlMessage(from: updateEnvelope.serialize())
        let decodedUpdate = try decodedUpdateEnvelope.decode(SharedClipboardUpdateMessage.self)
        #expect(decodedUpdate.sentAtMs == 1_234_567)
        #expect(decodedUpdate.encryptedText == Data([0x01, 0x02, 0x03]))
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
}
