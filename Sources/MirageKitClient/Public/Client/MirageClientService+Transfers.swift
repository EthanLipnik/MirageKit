//
//  MirageClientService+Transfers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/29/26.
//
//  Session-scoped Loom transfer observation and routing.
//

import Foundation
import Loom
import MirageKit

@MainActor
extension MirageClientService {
    func startTransferObserver() {
        transferObserverTask?.cancel()
        transferObserverTask = nil
        pendingIncomingTransfersByKey.removeAll(keepingCapacity: false)
        for (_, continuation) in transferWaitersByKey {
            continuation.resume(throwing: CancellationError())
        }
        transferWaitersByKey.removeAll(keepingCapacity: false)

        guard let transferEngine else { return }
        transferObserverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await transfer in transferEngine.incomingTransfers {
                let key = transferKey(
                    kind: transfer.offer.metadata["mirage.transfer-kind"] ?? "",
                    requestID: transfer.offer.metadata["mirage.request-id"] ?? ""
                )
                if let continuation = transferWaitersByKey.removeValue(forKey: key) {
                    continuation.resume(returning: transfer)
                } else {
                    pendingIncomingTransfersByKey[key] = transfer
                }
            }
        }
    }

    func stopTransferObserver() {
        transferObserverTask?.cancel()
        transferObserverTask = nil
        for (_, continuation) in transferWaitersByKey {
            continuation.resume(throwing: CancellationError())
        }
        transferWaitersByKey.removeAll(keepingCapacity: false)
        pendingIncomingTransfersByKey.removeAll(keepingCapacity: false)
    }

    func awaitIncomingTransfer(
        kind: String,
        requestID: UUID
    ) async throws -> LoomIncomingTransfer {
        let key = transferKey(kind: kind, requestID: requestID.uuidString.lowercased())
        if let pending = pendingIncomingTransfersByKey.removeValue(forKey: key) {
            return pending
        }

        return try await withCheckedThrowingContinuation { continuation in
            transferWaitersByKey[key] = continuation
        }
    }

    private func transferKey(kind: String, requestID: String) -> String {
        "\(kind)#\(requestID)"
    }
}
