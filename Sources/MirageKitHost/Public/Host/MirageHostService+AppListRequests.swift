//
//  MirageHostService+AppListRequests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Reports a malformed app-list request to the client without starting an app scan.
    func rejectMalformedAppListRequest(
        from clientContext: ClientContext,
        reason: String
    ) {
        MirageLogger.host("Rejecting malformed app list request from \(clientContext.client.name): \(reason)")
        let payload = ErrorMessage(
            code: .invalidMessage,
            message: "Invalid app list request payload"
        )
        clientContext.queueBestEffort(.error, content: payload)
    }

    /// Returns whether a thrown error came from an invalid app-list request payload.
    nonisolated static func isMalformedAppListRequestError(_ error: Error) -> Bool {
        if error is DecodingError {
            return true
        }

        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }

        switch nsError.code {
        case CocoaError.Code.coderReadCorrupt.rawValue,
             CocoaError.Code.coderValueNotFound.rawValue:
            return true
        default:
            return false
        }
    }

    /// Builds a host log message for a malformed app-list request error.
    nonisolated static func malformedAppListRequestReason(from error: Error) -> String {
        if let decodeError = error as? DecodingError {
            return String(describing: decodeError)
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.localizedDescription
        }

        return String(describing: error)
    }

    /// Handles a client's app-list request and defers delivery when interactive streaming work is active.
    func handleAppListRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    )
    async {
        do {
            let request = try message.decode(AppListRequestMessage.self)
            MirageLogger.host(
                "Client \(clientContext.client.name) requested app list (requestID: \(request.requestID.uuidString), forceRefresh: \(request.forceRefresh), forceIconReset: \(request.forceIconReset), priorityCount: \(request.priorityBundleIdentifiers.count), knownIconCount: \(request.knownIconBundleIdentifiers.count))"
            )

            updatePendingAppListRequest(
                clientID: clientContext.client.id,
                requestID: request.requestID,
                requestedForceRefresh: request.forceRefresh,
                forceIconReset: request.forceIconReset,
                priorityBundleIdentifiers: request.priorityBundleIdentifiers,
                knownIconBundleIdentifiers: request.knownIconBundleIdentifiers
            )

            await syncAppListRequestDeferralForInteractiveWorkload()
            sendPendingAppListRequestIfPossible()
        } catch {
            if Self.isMalformedAppListRequestError(error) {
                rejectMalformedAppListRequest(
                    from: clientContext,
                    reason: Self.malformedAppListRequestReason(from: error)
                )
                return
            }

            MirageLogger.error(.host, error: error, message: "Failed to handle app list request: ")
        }
    }
}

#endif
