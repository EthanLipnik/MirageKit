//
//  MirageSharedClipboardChunkBuffer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/25/26.
//

import Foundation

package struct MirageSharedClipboardChunkBuffer: Sendable {
    struct PendingTransfer: Sendable {
        let chunkCount: Int
        var chunks: [Int: String]
        let startedAt: ContinuousClock.Instant
    }

    private var pending: [UUID: PendingTransfer] = [:]
    private let timeout: Duration = .seconds(5)

    package init() {}

    /// Add a decrypted chunk. Returns the full reassembled text when all chunks arrive, nil otherwise.
    package mutating func addChunk(
        changeID: UUID,
        chunkIndex: Int,
        chunkCount: Int,
        text: String
    ) -> String? {
        evictStale()

        if chunkCount == 1 { return text }

        var transfer = pending[changeID] ?? PendingTransfer(
            chunkCount: chunkCount,
            chunks: [:],
            startedAt: .now
        )
        transfer.chunks[chunkIndex] = text

        if transfer.chunks.count == chunkCount {
            pending.removeValue(forKey: changeID)
            return (0 ..< chunkCount).compactMap { transfer.chunks[$0] }.joined()
        }

        pending[changeID] = transfer
        return nil
    }

    private mutating func evictStale() {
        let now = ContinuousClock.Instant.now
        pending = pending.filter { now - $0.value.startedAt < timeout }
    }
}
