//
//  MirageHostService+ConnectionFailures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import Foundation
import Loom
import Network
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// POSIX errors that mean the host-side control connection can no longer recover in-place.
    private nonisolated static let fatalConnectionPOSIXCodes: Set<POSIXErrorCode> = [
        .ECANCELED,
        .ECONNRESET,
        .ENOTCONN,
        .EPIPE,
        .EADDRNOTAVAIL,
        .ECONNREFUSED
    ]

    /// Loom errors that represent terminal session teardown rather than transient transport noise.
    private nonisolated static let fatalConnectionLoomCodes: Set<Int> = [0, 3]

    /// Whether a bootstrap failure represents expected peer/session teardown.
    nonisolated func isExpectedBootstrapConnectionClosure(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let mirageError = error as? MirageError {
            switch mirageError {
            case let .protocolError(message):
                return message == "Authenticated Loom session closed before Mirage control stream opened" ||
                    message == "Control stream closed before session bootstrap request"
            case let .connectionRejected(rejection):
                return rejection.isTerminal
            case let .connectionFailed(underlyingError):
                return isExpectedBootstrapConnectionClosure(underlyingError)
            default:
                break
            }
        }

        if let loomError = error as? LoomError {
            switch loomError {
            case let .connectionFailed(underlyingError):
                return isExpectedBootstrapConnectionClosure(underlyingError)
            default:
                break
            }
        }

        if let failure = error as? LoomConnectionFailure {
            switch failure.reason {
            case .cancelled, .closed:
                return true
            case .timedOut, .transportLoss, .connectionRefused, .addressUnavailable, .other:
                break
            }
        }

        return false
    }

    /// Whether an error means the underlying connection/session must be torn down.
    nonisolated func isFatalConnectionError(_ error: Error) -> Bool {
        if let mirageError = error as? MirageError {
            switch mirageError {
            case .authenticationFailed, .connectionFailed, .timeout:
                return true
            default:
                break
            }
        }

        if let nwError = error as? NWError {
            switch nwError {
            case let .posix(code):
                return Self.fatalConnectionPOSIXCodes.contains(code)
            default:
                break
            }
        }

        let nsError = error as NSError

        // LoomError(0) = cancelled, LoomError(3) = authenticationFailed.
        if nsError.domain == "Loom.LoomError" {
            return Self.fatalConnectionLoomCodes.contains(nsError.code)
        }

        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return Self.fatalConnectionPOSIXCodes.contains(code)
        }
        if nsError.domain == "NWError" {
            if nsError.code == -65554 || nsError.code == -65555 {
                return true
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain,
               let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
                return Self.fatalConnectionPOSIXCodes.contains(code)
            }
        }

        let desc = String(describing: error)
        if desc.contains("POSIXErrorCode(rawValue: 89)") ||
           desc.contains("POSIXErrorCode(rawValue: 61)") ||
           desc.contains("POSIXErrorCode(rawValue: 57)") ||
           desc.contains("POSIXErrorCode(rawValue: 54)") ||
           desc.contains("POSIXErrorCode(rawValue: 49)") ||
           desc.contains("POSIXErrorCode(rawValue: 32)") {
            return true
        }
        return false
    }

    /// Whether a failed lifecycle send is expected during normal disconnect/cancel teardown.
    nonisolated func isExpectedLifecycleControlSendFailure(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == "Loom.LoomError", nsError.code == 0 {
            return true
        }

        if let mirageError = error as? MirageError {
            switch mirageError {
            case let .connectionFailed(underlyingError):
                return isExpectedLifecycleControlSendFailure(underlyingError)
            default:
                break
            }
        }

        if let loomError = error as? LoomError {
            switch loomError {
            case let .connectionFailed(underlyingError):
                return isExpectedLifecycleControlSendFailure(underlyingError)
            default:
                break
            }
        }

        if let failure = error as? LoomConnectionFailure {
            switch failure.reason {
            case .cancelled, .closed:
                return true
            case .timedOut, .transportLoss, .connectionRefused, .addressUnavailable, .other:
                break
            }
        }

        return false
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
            LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
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

