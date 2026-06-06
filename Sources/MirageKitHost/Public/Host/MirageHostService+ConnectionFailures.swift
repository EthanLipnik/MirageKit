//
//  MirageHostService+ConnectionFailures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
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

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Whether a bootstrap failure represents expected peer/session teardown.
    nonisolated func isExpectedBootstrapConnectionClosure(_ error: Error) -> Bool {
        MirageConnectionErrorClassifier.isExpectedBootstrapConnectionClosure(error)
    }

    /// Whether an error means the underlying connection/session must be torn down.
    nonisolated func isFatalConnectionError(_ error: Error) -> Bool {
        MirageConnectionErrorClassifier.isFatalConnectionError(error)
    }

    /// Whether a failed lifecycle send is expected during normal disconnect/cancel teardown.
    nonisolated func isExpectedLifecycleControlSendFailure(_ error: Error) -> Bool {
        MirageConnectionErrorClassifier.isExpectedLifecycleControlSendFailure(error)
    }

    /// Logs a control-channel send failure once per client and disconnects unrecoverable sessions.
    func handleControlChannelSendFailure(
        client: MirageConnectedClient,
        error: Error,
        operation: String,
        sessionID: UUID? = nil
    ) async {
        if let sessionID,
           findClientContext(sessionID: sessionID)?.client.id != client.id {
            return
        }

        let isFirstFailure = controlChannelSendFailureReported.insert(client.id).inserted

        if isFatalConnectionError(error) ||
            isExpectedLifecycleControlSendFailure(error) ||
            MirageConnectionErrorClassifier.isLikelyUserDependent(error: error) {
            if isFirstFailure {
                MirageLogger.host(
                    "\(operation) skipped because the control channel closed for \(client.name): \(error.localizedDescription)"
                )
            }
        } else if isFirstFailure {
            MirageLogger.error(.host, error: error, message: "\(operation) failed: ")
        }

        guard clientsByID[client.id] != nil else { return }
        await disconnectClient(client, sessionID: sessionID, notifyClient: false)
    }
}
#endif
