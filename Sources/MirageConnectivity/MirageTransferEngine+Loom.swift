//
//  MirageTransferEngine+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom

package final class MirageTransferEngine: @unchecked Sendable {
    package let incomingTransfers: AsyncStream<MirageIncomingTransfer>

    private let loomEngine: LoomTransferEngine

    package convenience init(session: any LoomSessionProtocol) {
        self.init(loomEngine: LoomTransferEngine(session: session))
    }

    package init(loomEngine: LoomTransferEngine) {
        self.loomEngine = loomEngine
        incomingTransfers = AsyncStream { continuation in
            let task = Task {
                for await transfer in loomEngine.incomingTransfers {
                    continuation.yield(MirageIncomingTransfer(loomTransfer: transfer))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    package func offerQualityTestNoiseTransfer(
        testID: UUID
    ) async throws -> MirageOutgoingTransfer {
        try await offerTransfer(
            MirageTransferOffer(
                logicalName: MirageQualityTestTransfer.logicalName,
                byteLength: MirageQualityTestTransfer.byteCount,
                contentType: "application/octet-stream",
                metadata: MirageQualityTestTransfer.metadata(testID: testID)
            ),
            source: MirageQualityTestNoiseSource()
        )
    }

    package func offerFileTransfer(
        url: URL,
        logicalName: String? = nil,
        contentType: String?,
        metadata: [String: String]
    ) async throws -> MirageOutgoingTransfer {
        let source = try LoomFileTransferSource(url: url)
        let byteLength = await source.byteLength
        return try await offerTransfer(
            MirageTransferOffer(
                logicalName: logicalName ?? url.lastPathComponent,
                byteLength: byteLength,
                contentType: contentType,
                metadata: metadata
            ),
            source: source
        )
    }

    private func offerTransfer(
        _ offer: MirageTransferOffer,
        source: any LoomTransferSource
    ) async throws -> MirageOutgoingTransfer {
        let transfer = try await loomEngine.offerTransfer(offer.loomOffer, source: source)
        return MirageOutgoingTransfer(loomTransfer: transfer)
    }
}

package final class MirageOutgoingTransfer: @unchecked Sendable {
    package let offer: MirageTransferOffer
    package let progressEvents: AsyncStream<MirageTransferProgress>

    private let loomTransfer: LoomOutgoingTransfer

    fileprivate init(loomTransfer: LoomOutgoingTransfer) {
        self.loomTransfer = loomTransfer
        offer = MirageTransferOffer(loomOffer: loomTransfer.offer)
        progressEvents = MirageTransferProgress.progressEvents(from: loomTransfer.progressEvents)
    }

    package func cancel() async {
        await loomTransfer.cancel()
    }

    package nonisolated func makeProgressObserver() -> AsyncStream<MirageTransferProgress> {
        MirageTransferProgress.progressEvents(from: loomTransfer.makeProgressObserver())
    }
}

package final class MirageIncomingTransfer: @unchecked Sendable {
    package let offer: MirageTransferOffer
    package let progressEvents: AsyncStream<MirageTransferProgress>

    private let loomTransfer: LoomIncomingTransfer

    fileprivate init(loomTransfer: LoomIncomingTransfer) {
        self.loomTransfer = loomTransfer
        offer = MirageTransferOffer(loomOffer: loomTransfer.offer)
        progressEvents = MirageTransferProgress.progressEvents(from: loomTransfer.progressEvents)
    }

    package func acceptFileTransfer(to url: URL) async throws {
        let sink = try LoomFileTransferSink(url: url)
        try await loomTransfer.accept(using: sink)
    }

    package func acceptDiscardingQualityTestTransfer() async throws -> MirageQualityTestDiscardSink {
        let sink = MirageQualityTestDiscardSink()
        try await loomTransfer.accept(using: sink)
        return sink
    }

    package func decline() async throws {
        try await loomTransfer.decline()
    }
}
