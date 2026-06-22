//
//  MirageTransferProgress+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 5/11/26.
//

import Foundation
import Loom

package struct MirageTransferOffer: Sendable, Hashable {
    package let id: UUID
    package let logicalName: String
    package let byteLength: UInt64
    package let contentType: String?
    package let sha256Hex: String?
    package let metadata: [String: String]

    package init(
        id: UUID = UUID(),
        logicalName: String,
        byteLength: UInt64,
        contentType: String? = nil,
        sha256Hex: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.logicalName = logicalName
        self.byteLength = byteLength
        self.contentType = contentType
        self.sha256Hex = sha256Hex?.lowercased()
        self.metadata = metadata
    }

    package init(loomOffer offer: LoomTransferOffer) {
        self.init(
            id: offer.id,
            logicalName: offer.logicalName,
            byteLength: offer.byteLength,
            contentType: offer.contentType,
            sha256Hex: offer.sha256Hex,
            metadata: offer.metadata
        )
    }

    package var loomOffer: LoomTransferOffer {
        LoomTransferOffer(
            id: id,
            logicalName: logicalName,
            byteLength: byteLength,
            contentType: contentType,
            sha256Hex: sha256Hex,
            metadata: metadata
        )
    }
}

package enum MirageTransferState: String, Sendable, Codable {
    case offered
    case waitingForAcceptance
    case transferring
    case completed
    case cancelled
    case failed
    case declined

    package init(loomState state: LoomTransferState) {
        switch state {
        case .offered:
            self = .offered
        case .waitingForAcceptance:
            self = .waitingForAcceptance
        case .transferring:
            self = .transferring
        case .completed:
            self = .completed
        case .cancelled:
            self = .cancelled
        case .failed:
            self = .failed
        case .declined:
            self = .declined
        }
    }
}

/// Mirage-owned transfer progress snapshot used by runtime control-flow decisions.
package struct MirageTransferProgress: Sendable, Equatable {
    package let transferID: UUID
    package let logicalName: String
    package let bytesTransferred: UInt64
    package let totalBytes: UInt64
    package let state: MirageTransferState

    package init(
        transferID: UUID,
        logicalName: String,
        bytesTransferred: UInt64,
        totalBytes: UInt64,
        state: MirageTransferState
    ) {
        self.transferID = transferID
        self.logicalName = logicalName
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.state = state
    }

    package init(loomProgress progress: LoomTransferProgress) {
        self.init(
            transferID: progress.transferID,
            logicalName: progress.logicalName,
            bytesTransferred: progress.bytesTransferred,
            totalBytes: progress.totalBytes,
            state: MirageTransferState(loomState: progress.state)
        )
    }

    package static func progressEvents(
        from stream: AsyncStream<LoomTransferProgress>
    ) -> AsyncStream<MirageTransferProgress> {
        AsyncStream { continuation in
            let task = Task {
                for await progress in stream {
                    continuation.yield(MirageTransferProgress(loomProgress: progress))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Returns the first terminal progress event, or the last observed event if the stream ends early.
    package static func terminalProgress(
        from stream: AsyncStream<MirageTransferProgress>
    ) async -> MirageTransferProgress? {
        var lastProgress: MirageTransferProgress?
        for await progress in stream {
            lastProgress = progress
            switch progress.state {
            case .completed, .cancelled, .failed, .declined:
                return progress
            case .offered, .waitingForAcceptance, .transferring:
                break
            }
        }
        return lastProgress
    }

    /// Returns the first terminal progress event, or the last observed event if the stream ends early.
    package static func terminalProgress(
        from stream: AsyncStream<LoomTransferProgress>
    ) async -> MirageTransferProgress? {
        await terminalProgress(from: progressEvents(from: stream))
    }
}
