//
//  SharedClipboardChunkingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKit
import Foundation
import Testing

extension SharedClipboardTests {
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
