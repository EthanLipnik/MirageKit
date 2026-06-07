//
//  MirageClientService+Transfers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/29/26.
//
//  Session-scoped transfer observation and routing.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

@MainActor
extension MirageClientService {
    func startTransferObserver() {
        transferObserverTask?.cancel()
        transferObserverTask = nil
        pendingIncomingTransfersByKey.removeAll(keepingCapacity: false)
        cancelTransferWaiters()

        guard let transferEngine else { return }
        transferObserverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await transfer in transferEngine.incomingTransfers {
                let kind = transfer.offer.metadata["mirage.transfer-kind"] ?? ""
                let requestID = transfer.offer.metadata["mirage.request-id"] ?? ""
                let key = transferKey(kind: kind, requestID: requestID)
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
        cancelTransferWaiters()
        pendingIncomingTransfersByKey.removeAll(keepingCapacity: false)
    }

    func awaitIncomingTransfer(
        kind: String,
        requestID: UUID
    ) async throws -> MirageIncomingTransfer {
        let key = transferKey(kind: kind, requestID: requestID.uuidString.lowercased())
        if let pending = pendingIncomingTransfersByKey.removeValue(forKey: key) {
            return pending
        }

        return try await withCheckedThrowingContinuation { continuation in
            transferWaitersByKey[key] = continuation
        }
    }

    /// Stable lookup key for matching Loom transfer offers to Mirage control requests.
    private func transferKey(kind: String, requestID: String) -> String {
        "\(kind)#\(requestID)"
    }

    /// Cancels pending transfer waiters when the authenticated transfer session changes.
    private func cancelTransferWaiters() {
        for continuation in transferWaitersByKey.values {
            continuation.resume(throwing: CancellationError())
        }
        transferWaitersByKey.removeAll(keepingCapacity: false)
    }
}
