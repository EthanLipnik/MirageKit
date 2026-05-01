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

    @Test("Shared clipboard metadata-only messages default to single chunk")
    func sharedClipboardMessageDefaultChunk() throws {
        let update = SharedClipboardUpdateMessage(
            changeID: UUID(),
            logicalVersion: 7,
            sentAtMs: 100,
            source: .host,
            representation: MirageSharedClipboardItem.unsupported(byteCount: 90_000).representation,
            isPayloadTransferable: false,
            encryptedPayload: nil
        )
        #expect(update.logicalVersion == 7)
        #expect(update.chunkIndex == 0)
        #expect(update.chunkCount == 1)
        #expect(update.encryptedPayload == nil)
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
        #expect(MirageSharedClipboard.validatedPayload(nil) == nil)
        #expect(MirageSharedClipboard.validatedPayload(Data()) == nil)
        #expect(MirageSharedClipboard.validatedPayload(oversized) == nil)
        #expect(MirageSharedClipboard.validatedPayload(Data("clipboard".utf8)) == Data("clipboard".utf8))
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

        let remoteToken = MirageSharedClipboardOrderingToken(
            logicalVersion: 1,
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )
        state.recordRemoteDeclaration(changeCount: 5, orderingToken: remoteToken)

        #expect(state.prepareLocalSend(currentItem: textItem("old-client"), changeCount: 5) == nil)
        let localSend = state.prepareLocalSend(currentItem: textItem("new-client"), changeCount: 6)
        #expect(localSend?.text == "new-client")
        #expect(localSend?.orderingToken.logicalVersion == 2)
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

    @Test("chunkPayload returns single chunk for small data")
    func chunkPayloadSmall() {
        let payload = Data("Hello, world!".utf8)
        let chunks = MirageSharedClipboard.chunkPayload(payload)
        #expect(chunks.count == 1)
        #expect(chunks[0] == payload)
    }

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

    @Test("Chunk buffer returns payload immediately for single chunk")
    func chunkBufferSingleChunk() {
        var buffer = MirageSharedClipboardChunkBuffer()
        let id = UUID()
        let payload = Data("hello".utf8)
        let result = buffer.addChunk(changeID: id, chunkIndex: 0, chunkCount: 1, payload: payload)
        #expect(result == payload)
    }

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
