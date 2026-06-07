//
//  MirageConnectionErrorClassifier+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageCore
import Network

/// Classifies Loom-backed connection errors without requiring host policy code to import Loom.
package enum MirageConnectionErrorClassifier {
    /// POSIX errors that mean the control connection can no longer recover in-place.
    private static let fatalConnectionPOSIXCodes: Set<POSIXErrorCode> = [
        .ECANCELED,
        .ECONNRESET,
        .ENOTCONN,
        .EPIPE,
        .EADDRNOTAVAIL,
        .ECONNREFUSED
    ]

    /// Loom errors that represent terminal session teardown rather than transient transport noise.
    private static let fatalConnectionLoomCodes: Set<Int> = [0, 3]

    /// Classifies transport failures while opening a client control session.
    package static func classifyControlSessionFailure(
        _ error: Error
    ) -> MirageControlSessionFailureClassification {
        if error is CancellationError {
            return .cancelled
        }

        if let mirageError = error as? MirageCore.MirageError {
            switch mirageError {
            case .timeout:
                return .timeout
            case let .protocolError(reason):
                return classifyProtocolErrorReason(reason) ?? .other
            case let .connectionFailed(underlyingError):
                return classifyControlSessionFailure(underlyingError)
            default:
                break
            }
        }

        if let loomError = error as? LoomError {
            switch loomError {
            case .timeout:
                return .timeout
            case let .protocolError(reason):
                return classifyProtocolErrorReason(reason) ?? .other
            case let .connectionFailed(underlyingError):
                if let failure = underlyingError as? LoomConnectionFailure {
                    return classifyLoomConnectionFailure(failure)
                }
                return classifyControlSessionFailure(underlyingError)
            default:
                break
            }
        }

        if let failure = error as? LoomConnectionFailure {
            return classifyLoomConnectionFailure(failure)
        }

        if let nwError = error as? NWError {
            return classifyNetworkFailure(nwError)
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return classifyPOSIXError(code)
        }

        return .other
    }

    /// Whether a bootstrap failure represents expected peer/session teardown.
    package static func isExpectedBootstrapConnectionClosure(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let mirageError = error as? MirageCore.MirageError {
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
    package static func isFatalConnectionError(_ error: Error) -> Bool {
        if let mirageError = error as? MirageCore.MirageError {
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
                return fatalConnectionPOSIXCodes.contains(code)
            default:
                break
            }
        }

        let nsError = error as NSError

        if nsError.domain == "Loom.LoomError" {
            return fatalConnectionLoomCodes.contains(nsError.code)
        }

        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return fatalConnectionPOSIXCodes.contains(code)
        }
        if nsError.domain == "NWError" {
            if nsError.code == -65554 || nsError.code == -65555 {
                return true
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain,
               let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
                return fatalConnectionPOSIXCodes.contains(code)
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
    package static func isExpectedLifecycleControlSendFailure(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == "Loom.LoomError", nsError.code == 0 {
            return true
        }

        if let mirageError = error as? MirageCore.MirageError {
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

    /// Whether Loom diagnostics would treat an error as likely caused by user-controlled environment.
    package static func isLikelyUserDependent(error: Error) -> Bool {
        LoomDiagnosticsActionability.isLikelyUserDependent(error: error)
    }

    /// Whether a Loom-backed audio send failure represents recoverable send pressure.
    package static func isRecoverableAudioSendPressure(_ error: Error) -> Bool {
        if let loomError = error as? LoomError {
            switch loomError {
            case let .connectionFailed(underlyingError):
                return isRecoverableAudioSendPressure(underlyingError)
            default:
                return false
            }
        }

        if let mirageError = error as? MirageCore.MirageError {
            switch mirageError {
            case let .connectionFailed(underlyingError):
                return isRecoverableAudioSendPressure(underlyingError)
            default:
                return false
            }
        }

        if let failure = error as? LoomConnectionFailure {
            return failure.posixCode == .ECANCELED ||
                failure.detail == "Unreliable send queue cancelled."
        }

        return false
    }

    /// Whether best-effort input send failure is expected during normal stream teardown.
    package static func isExpectedBestEffortInputSendFailure(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let mirageError = error as? MirageCore.MirageError {
            switch mirageError {
            case let .connectionFailed(underlyingError):
                return isExpectedBestEffortInputSendFailure(underlyingError)
            default:
                break
            }
        }

        if let loomError = error as? LoomError {
            switch loomError {
            case let .connectionFailed(underlyingError):
                return isExpectedBestEffortInputSendFailure(underlyingError)
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

        if let nwError = error as? NWError {
            switch nwError {
            case let .posix(code):
                return isExpectedBestEffortInputPOSIXCode(code)
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == "Loom.LoomError" {
            return nsError.code == 0 || nsError.code == 3
        }
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return isExpectedBestEffortInputPOSIXCode(code)
        }
        return false
    }

    /// Whether a realtime priority-input send failure is an expected queue cancellation.
    package static func isExpectedRealtimeInputQueueDrop(_ error: Error) -> Bool {
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(.ECANCELED):
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(POSIXErrorCode.ECANCELED.rawValue)
    }

    /// Whether a host listener start failure should be retried after cleaning up stale listeners.
    package static func isRetryableListenerStartError(_ error: Error) -> Bool {
        guard let nwError = error as? NWError else { return false }
        switch nwError {
        case .posix(.EADDRINUSE), .posix(.EADDRNOTAVAIL):
            return true
        default:
            return false
        }
    }

    /// Classifies human-readable protocol errors produced before typed failure details are available.
    private static func classifyProtocolErrorReason(
        _ reason: String
    ) -> MirageControlSessionFailureClassification? {
        if looksLikeProximityPathValidationFailure(reason) {
            return .transportLoss
        }
        if looksLikeAddressResolutionFailure(reason) {
            return .addressUnavailable
        }
        if looksLikeBootstrapResponseTimeout(reason) {
            return .timeout
        }
        if looksLikeBootstrapTransportFailure(reason) {
            return .transportLoss
        }
        return nil
    }

    private static func looksLikeProximityPathValidationFailure(_ reason: String) -> Bool {
        reason.lowercased().contains("proximity path validation failed")
    }

    private static func looksLikeAddressResolutionFailure(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("failed to resolve") ||
            normalized.contains("nodename nor servname provided") ||
            normalized.contains("name or service not known")
    }

    private static func looksLikeBootstrapResponseTimeout(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("timed out waiting for host bootstrap response")
    }

    private static func looksLikeBootstrapTransportFailure(_ reason: String) -> Bool {
        let normalized = reason.lowercased()
        return normalized.contains("control stream closed before receiving bootstrap response") ||
            normalized.contains("authenticated loom session closed before mirage control stream opened")
    }

    private static func classifyLoomConnectionFailure(
        _ failure: LoomConnectionFailure
    ) -> MirageControlSessionFailureClassification {
        switch failure.reason {
        case .timedOut:
            .timeout
        case .transportLoss, .closed:
            .transportLoss
        case .connectionRefused:
            .connectionRefused
        case .addressUnavailable:
            .addressUnavailable
        case .cancelled:
            .cancelled
        case .other:
            .other
        }
    }

    private static func classifyNetworkFailure(
        _ error: NWError
    ) -> MirageControlSessionFailureClassification {
        switch error {
        case let .posix(code):
            return classifyPOSIXError(code)
        case .dns:
            return .addressUnavailable
        case .tls:
            return .other
        case .wifiAware:
            return .other
        @unknown default:
            return .other
        }
    }

    private static func classifyPOSIXError(
        _ code: POSIXErrorCode
    ) -> MirageControlSessionFailureClassification {
        switch code {
        case .ETIMEDOUT:
            .timeout
        case .ECONNREFUSED:
            .connectionRefused
        case .EADDRNOTAVAIL:
            .addressUnavailable
        case .ENETDOWN,
             .ENETUNREACH,
             .EHOSTDOWN,
             .EHOSTUNREACH,
             .ENETRESET,
             .ECONNABORTED,
             .ECONNRESET,
             .ENOTCONN,
             .EPIPE:
            .transportLoss
        case .ECANCELED:
            .cancelled
        default:
            .other
        }
    }

    private static func isExpectedBestEffortInputPOSIXCode(_ code: POSIXErrorCode) -> Bool {
        switch code {
        case .EPIPE, .ECONNRESET, .ENOTCONN, .ECANCELED:
            true
        default:
            false
        }
    }
}

/// Product-neutral classification of client control-session setup failures.
package enum MirageControlSessionFailureClassification: String, Sendable {
    case timeout
    case transportLoss
    case connectionRefused
    case addressUnavailable
    case cancelled
    case other
}
