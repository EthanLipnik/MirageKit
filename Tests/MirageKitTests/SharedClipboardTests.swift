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
                source: .host,
                representation: representation,
                isPayloadTransferable: true,
                encryptedPayload: Data([0x01, 0x02, 0x03]),
                chunkIndex: 2,
                chunkCount: 5
            )
        )
        let (decodedUpdateEnvelope, _) = try requireParsedControlMessage(from: updateEnvelope.serialize())
        let decodedUpdate = try decodedUpdateEnvelope.decode(SharedClipboardUpdateMessage.self)
        #expect(decodedUpdate.logicalVersion == 42)
        #expect(decodedUpdate.sentAtMs == 1_234_567)
        #expect(decodedUpdate.source == .host)
        #expect(decodedUpdate.representation == representation)
        #expect(decodedUpdate.isPayloadTransferable)
        #expect(decodedUpdate.encryptedPayload == Data([0x01, 0x02, 0x03]))
        #expect(decodedUpdate.chunkIndex == 2)
        #expect(decodedUpdate.chunkCount == 5)
    }

    @Test("Shared clipboard crypto round-trips binary payloads")
    func sharedClipboardCryptoRoundTrip() throws {
        let context = MirageMediaSecurityContext(
            sessionKey: Data(repeating: 0x4D, count: MirageMediaSecurity.sessionKeyLength),
            udpRegistrationToken: Data(repeating: 0x52, count: MirageMediaSecurity.registrationTokenLength)
        )
        let payload = Data([0x00, 0xFE, 0x7A])
        let encryptedPayload = try MirageMediaSecurity.encryptClipboardPayload(payload, context: context)
        let decryptedPayload = try MirageMediaSecurity.decryptClipboardPayload(encryptedPayload, context: context)
        #expect(decryptedPayload == payload)
    }

    @Test("Shared clipboard oversized and empty payloads are rejected")
    func sharedClipboardOversizeDropBehavior() {
        let oversized = Data(repeating: 0x61, count: MirageSharedClipboard.maximumPayloadBytes + 1)
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

        #expect(MirageSharedClipboard.validatedPayload(nil) == nil)
        #expect(MirageSharedClipboard.validatedPayload(Data()) == nil)
        #expect(MirageSharedClipboard.validatedPayload(oversized) == nil)
        #expect(MirageSharedClipboard.validatedPayload(Data("clipboard".utf8)) == Data("clipboard".utf8))
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
            sessionKey: Data(repeating: 0x4D, count: MirageMediaSecurity.sessionKeyLength),
            udpRegistrationToken: Data(repeating: 0x52, count: MirageMediaSecurity.registrationTokenLength)
        )

        let messages = try MirageSharedClipboard.makeUpdateMessages(
            localSend: localSend,
            sentAtMs: 123,
            mediaSecurityContext: context,
            source: .client
        )

        #expect(messages.count == MirageSharedClipboard.maximumTextPayloadBytes / MirageSharedClipboard.chunkSize)
    }

    @Test("Shared clipboard accepts newer logical versions despite physical clock skew")
    func sharedClipboardAcceptsNewerLogicalVersionsDespiteClockSkew() {
        var state = MirageSharedClipboardState()

        state.activate(changeCount: 7)
        let localSend = state.prepareLocalSend(currentItem: textItem("fresh"), changeCount: 8).requiredLocalSend
        let localToken = localSend.orderingToken
        #expect(localToken.logicalVersion == 1)
        #expect(
            state.shouldApplyRemoteUpdate(
                orderingToken: MirageSharedClipboardOrderingToken(
                    logicalVersion: 2,
                    changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                )
            )
        )
        #expect(
            !state.shouldApplyRemoteUpdate(
                orderingToken: MirageSharedClipboardOrderingToken(
                    logicalVersion: localToken.logicalVersion,
                    changeID: localToken.changeID
                )
            )
        )
    }

    @Test("Metadata-only host declarations suppress stale client paste sync")
    func metadataOnlyHostDeclarationSuppressesStaleClientSync() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 5)
        let observedAtMs: Int64 = 10_000

        let remoteToken = MirageSharedClipboardOrderingToken(
            logicalVersion: 1,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )
        state.recordRemoteDeclaration(
            changeCount: 5,
            orderingToken: remoteToken,
            observedAtMs: observedAtMs
        )

        #expect(
            state.prepareLocalSend(
                currentItem: textItem("old-client"),
                changeCount: 5,
                nowMs: observedAtMs
            ) == nil
        )
        let localSend = state.prepareLocalSend(
            currentItem: textItem("new-client"),
            changeCount: 6,
            nowMs: afterRemoteWindow(from: observedAtMs)
        )
        #expect(localSend?.text == "new-client")
        #expect(localSend?.orderingToken.logicalVersion == 2)
    }

    @Test("Metadata-only host declaration allows existing client clipboard change after recent window")
    func metadataOnlyHostDeclarationAllowsExistingClientChangeAfterRecentWindow() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 5)
        let observedAtMs: Int64 = 20_000

        let remoteToken = MirageSharedClipboardOrderingToken(
            logicalVersion: 1,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        )
        state.recordRemoteDeclaration(
            changeCount: 6,
            orderingToken: remoteToken,
            observedAtMs: observedAtMs
        )

        let localSend = state.prepareLocalSend(
            currentItem: textItem("client-newer"),
            changeCount: 6,
            nowMs: afterRemoteWindow(from: observedAtMs)
        )
        #expect(localSend?.text == "client-newer")
        #expect(localSend?.orderingToken.logicalVersion == 2)
    }

    @Test("Payload-bearing host observation suppresses client paste sync before apply")
    func payloadBearingHostObservationSuppressesClientPasteSyncBeforeApply() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 5)
        let observedAtMs: Int64 = 30_000
        let remoteToken = MirageSharedClipboardOrderingToken(
            logicalVersion: 3,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        )

        let recorded = state.recordRemoteTransferObservation(
            changeCount: 5,
            orderingToken: remoteToken,
            observedAtMs: observedAtMs
        )
        #expect(recorded)
        #expect(state.latestOrderingToken == nil)
        #expect(state.shouldApplyRemoteUpdate(orderingToken: remoteToken))
        #expect(
            state.prepareLocalSend(
                currentItem: textItem("client"),
                changeCount: 5,
                nowMs: observedAtMs
            ) == nil
        )
    }

    @Test("Observed host token can still be finalized")
    func observedHostTokenCanStillBeFinalized() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 5)
        let remoteToken = MirageSharedClipboardOrderingToken(
            logicalVersion: 4,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        )

        let recordedObservation = state.recordRemoteTransferObservation(
            changeCount: 5,
            orderingToken: remoteToken,
            observedAtMs: 40_000
        )
        #expect(recordedObservation)

        #expect(state.shouldApplyRemoteUpdate(orderingToken: remoteToken))
        state.recordRemoteWrite(changeCount: 6, orderingToken: remoteToken)
        #expect(state.latestOrderingToken == remoteToken)
        #expect(!state.shouldApplyRemoteUpdate(orderingToken: remoteToken))
    }

    @Test("Client pasteboard changes inside recent host window are treated as host-origin")
    func clientPasteboardChangesInsideRecentHostWindowAreTreatedAsHostOrigin() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 10)
        let observedAtMs: Int64 = 50_000
        let remoteToken = MirageSharedClipboardOrderingToken(
            logicalVersion: 1,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        )

        let recordedObservation = state.recordRemoteTransferObservation(
            changeCount: 10,
            orderingToken: remoteToken,
            observedAtMs: observedAtMs
        )
        #expect(recordedObservation)

        #expect(
            state.prepareLocalSend(
                currentItem: textItem("maybe-host"),
                changeCount: 11,
                nowMs: observedAtMs + MirageSharedClipboard.recentRemoteClipboardChangeWindowMilliseconds
            ) == nil
        )
        #expect(
            state.prepareLocalSend(
                currentItem: textItem("maybe-host"),
                changeCount: 11,
                nowMs: afterRemoteWindow(from: observedAtMs)
            ) == nil
        )
    }

    @Test("Client pasteboard changes after recent host window can sync")
    func clientPasteboardChangesAfterRecentHostWindowCanSync() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 10)
        let observedAtMs: Int64 = 60_000
        let remoteToken = MirageSharedClipboardOrderingToken(
            logicalVersion: 1,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
        )

        let recordedObservation = state.recordRemoteTransferObservation(
            changeCount: 10,
            orderingToken: remoteToken,
            observedAtMs: observedAtMs
        )
        #expect(recordedObservation)

        let localSend = state.prepareLocalSend(
            currentItem: textItem("client-newer"),
            changeCount: 11,
            nowMs: afterRemoteWindow(from: observedAtMs)
        )

        #expect(localSend?.text == "client-newer")
        #expect(localSend?.orderingToken.logicalVersion == 2)
    }

    @Test("Stale host observations do not override newer ordering")
    func staleHostObservationsDoNotOverrideNewerOrdering() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 0)
        let newerToken = MirageSharedClipboardOrderingToken(
            logicalVersion: 5,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        )
        let olderToken = MirageSharedClipboardOrderingToken(
            logicalVersion: 4,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        )

        let recordedNewer = state.recordRemoteTransferObservation(
            changeCount: 0,
            orderingToken: newerToken,
            observedAtMs: 70_000
        )
        let recordedOlder = state.recordRemoteTransferObservation(
            changeCount: 1,
            orderingToken: olderToken,
            observedAtMs: 71_000
        )
        #expect(recordedNewer)
        #expect(!recordedOlder)
        #expect(state.latestRemoteClipboardObservedAtMs == 70_000)

        let localSend = state.prepareLocalSend(
            currentItem: textItem("client-newer"),
            changeCount: 1,
            nowMs: afterRemoteWindow(from: 70_000)
        )
        #expect(localSend?.orderingToken.logicalVersion == 6)
        let recordedOlderAfterLocalSend = state.recordRemoteTransferObservation(
            changeCount: 2,
            orderingToken: olderToken,
            observedAtMs: 74_000
        )
        #expect(!recordedOlderAfterLocalSend)
    }

    @Test("Host-applied payload is not sent back on next client paste")
    func hostAppliedPayloadIsNotEchoed() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 1)

        let remoteToken = MirageSharedClipboardOrderingToken(
            logicalVersion: 8,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
        )
        state.recordRemoteWrite(changeCount: 2, orderingToken: remoteToken)

        #expect(state.prepareLocalSend(currentItem: textItem("host-value"), changeCount: 2) == nil)
    }

    @Test("Manual shared clipboard stays live across repeated client pastes")
    func manualSharedClipboardStaysLiveAcrossRepeatedClientPastes() {
        var clientState = MirageSharedClipboardState()
        var hostState = MirageSharedClipboardState()

        clientState.activate(changeCount: 0)
        hostState.activate(changeCount: 0)

        let clientFirst = clientState.prepareLocalSend(currentItem: textItem("client-1"), changeCount: 1).requiredLocalSend
        #expect(clientFirst.text == "client-1")
        #expect(hostState.shouldApplyRemoteUpdate(orderingToken: clientFirst.orderingToken))
        hostState.recordRemoteWrite(
            changeCount: 1,
            orderingToken: clientFirst.orderingToken
        )

        let clientSecond = clientState.prepareLocalSend(currentItem: textItem("client-2"), changeCount: 2).requiredLocalSend
        #expect(clientSecond.text == "client-2")
        #expect(hostState.shouldApplyRemoteUpdate(orderingToken: clientSecond.orderingToken))
        hostState.recordRemoteWrite(
            changeCount: 2,
            orderingToken: clientSecond.orderingToken
        )
    }

    @Test("Automatic shared clipboard suppresses duplicate content fingerprints")
    func automaticSharedClipboardSuppressesDuplicateContentFingerprints() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 0)

        let first = state.prepareLocalDeclaration(item: textItem("same"), changeCount: 1)
        let duplicateWithNewChangeCount = state.prepareLocalDeclaration(item: textItem("same"), changeCount: 2)
        let changed = state.prepareLocalDeclaration(item: textItem("different"), changeCount: 3)

        #expect(first?.text == "same")
        #expect(duplicateWithNewChangeCount == nil)
        #expect(changed?.text == "different")
    }

    @Test("Manual shared clipboard does not use automatic duplicate fingerprint suppression")
    func manualSharedClipboardDoesNotUseAutomaticDuplicateSuppression() {
        var state = MirageSharedClipboardState()
        state.activate(changeCount: 0)

        let first = state.prepareLocalSend(currentItem: textItem("same"), changeCount: 1)
        let second = state.prepareLocalSend(currentItem: textItem("same"), changeCount: 2)

        #expect(first?.text == "same")
        #expect(second?.text == "same")
        #expect(first?.orderingToken != second?.orderingToken)
    }

    @Test("Automatic shared clipboard chunks are paced during streaming")
    func automaticSharedClipboardChunksArePacedDuringStreaming() {
        #expect(MirageSharedClipboard.automaticStreamChunkPacingDelay > .zero)
    }

    @Test("Shared clipboard tie-breaks concurrent logical versions deterministically")
    func sharedClipboardTieBreaksConcurrentLogicalVersionsDeterministically() {
        let tokenA = MirageSharedClipboardOrderingToken(
            logicalVersion: 7,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        )
        let tokenB = MirageSharedClipboardOrderingToken(
            logicalVersion: 7,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        )
        let expectedWinner = max(tokenA, tokenB)

        var leftToRight = MirageSharedClipboardState()
        leftToRight.activate(changeCount: 0)
        leftToRight.recordRemoteWrite(changeCount: 1, orderingToken: tokenA)
        if leftToRight.shouldApplyRemoteUpdate(orderingToken: tokenB) {
            leftToRight.recordRemoteWrite(changeCount: 2, orderingToken: tokenB)
        }

        var rightToLeft = MirageSharedClipboardState()
        rightToLeft.activate(changeCount: 0)
        rightToLeft.recordRemoteWrite(changeCount: 1, orderingToken: tokenB)
        if rightToLeft.shouldApplyRemoteUpdate(orderingToken: tokenA) {
            rightToLeft.recordRemoteWrite(changeCount: 2, orderingToken: tokenA)
        }

        #expect(leftToRight.latestOrderingToken == expectedWinner)
        #expect(rightToLeft.latestOrderingToken == expectedWinner)
    }

    // MARK: - Chunking

    @Test("chunkPayload splits large data")
    func chunkPayloadLarge() {
        let payload = Data(repeating: 0x41, count: 10_000)
        let chunks = MirageSharedClipboard.chunkPayload(payload)
        #expect(chunks.count > 1)
        #expect(chunks.reduce(into: Data()) { $0.append($1) } == payload)
        for chunk in chunks {
            #expect(chunk.count <= MirageSharedClipboard.chunkSize)
        }
    }

    // MARK: - Chunk Buffer

    @Test("Chunk buffer reassembles multiple chunks in order")
    func chunkBufferMultipleChunks() {
        var buffer = MirageSharedClipboardChunkBuffer()
        let id = UUID()
        #expect(buffer.addChunk(changeID: id, chunkIndex: 0, chunkCount: 3, payload: Data("aaa".utf8)) == nil)
        #expect(buffer.addChunk(changeID: id, chunkIndex: 2, chunkCount: 3, payload: Data("ccc".utf8)) == nil)
        let result = buffer.addChunk(changeID: id, chunkIndex: 1, chunkCount: 3, payload: Data("bbb".utf8))
        #expect(result == Data("aaabbbccc".utf8))
    }

    @Test("Chunk buffer handles interleaved transfers")
    func chunkBufferInterleaved() {
        var buffer = MirageSharedClipboardChunkBuffer()
        let id1 = UUID()
        let id2 = UUID()
        #expect(buffer.addChunk(changeID: id1, chunkIndex: 0, chunkCount: 2, payload: Data("A".utf8)) == nil)
        #expect(buffer.addChunk(changeID: id2, chunkIndex: 0, chunkCount: 2, payload: Data("X".utf8)) == nil)
        #expect(buffer.addChunk(changeID: id1, chunkIndex: 1, chunkCount: 2, payload: Data("B".utf8)) == Data("AB".utf8))
        #expect(buffer.addChunk(changeID: id2, chunkIndex: 1, chunkCount: 2, payload: Data("Y".utf8)) == Data("XY".utf8))
    }
}

private extension MirageSharedClipboardLocalSend {
    var text: String? {
        guard let payload = item.payload else { return nil }
        return String(data: payload, encoding: .utf8)
    }
}

private func textItem(_ text: String) -> MirageSharedClipboardItem {
    let payload = Data(text.utf8)
    return MirageSharedClipboardItem(
        representation: SharedClipboardRepresentation(
            kind: .text,
            contentType: "public.utf8-plain-text",
            filename: nil,
            byteCount: payload.count
        ),
        payload: payload
    )
}

private func afterRemoteWindow(from observedAtMs: Int64) -> Int64 {
    observedAtMs + MirageSharedClipboard.recentRemoteClipboardChangeWindowMilliseconds + 1
}

private extension Optional where Wrapped == MirageSharedClipboardLocalSend {
    var requiredLocalSend: MirageSharedClipboardLocalSend {
        guard let self else {
            Issue.record("Expected local clipboard change to produce an outbound send.")
            return MirageSharedClipboardLocalSend(
                item: MirageSharedClipboardItem.unsupported(),
                orderingToken: MirageSharedClipboardOrderingToken(
                    logicalVersion: 0,
                    changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                )
            )
        }
        return self
    }
}
