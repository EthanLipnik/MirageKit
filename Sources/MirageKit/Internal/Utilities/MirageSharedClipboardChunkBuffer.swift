//
//  MirageSharedClipboardChunkBuffer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/25/26.
//

import Foundation

package struct MirageSharedClipboardChunkBuffer: Sendable {
    /// Maximum age for an incomplete clipboard chunk transfer before it is discarded.
    private static let transferTimeout: Duration = .seconds(5)

    struct PendingTransfer: Sendable {
        let chunkCount: Int
        var chunks: [Int: Data]
        let startedAt: ContinuousClock.Instant
    }

    private var pending: [UUID: PendingTransfer] = [:]

    package init() {}

    /// Add a decrypted chunk. Returns the full reassembled payload when all chunks arrive, nil otherwise.
    package mutating func addChunk(
        changeID: UUID,
        chunkIndex: Int,
        chunkCount: Int,
        payload: Data
    ) -> Data? {
        evictStale()

        if chunkCount == 1 { return payload }

        var transfer = pending[changeID] ?? PendingTransfer(
            chunkCount: chunkCount,
            chunks: [:],
            startedAt: .now
        )
        guard transfer.chunkCount == chunkCount,
              chunkIndex >= 0,
              chunkIndex < chunkCount else {
            return nil
        }
        transfer.chunks[chunkIndex] = payload

        if transfer.chunks.count == chunkCount {
            pending.removeValue(forKey: changeID)
            var data = Data()
            for index in 0 ..< chunkCount {
                guard let chunk = transfer.chunks[index] else { return nil }
                data.append(chunk)
            }
            return data
        }

        pending[changeID] = transfer
        return nil
    }

    private mutating func evictStale() {
        let now = ContinuousClock.Instant.now
        pending = pending.filter { now - $0.value.startedAt < Self.transferTimeout }
    }
}
