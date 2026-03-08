//
//  MirageDiagnosticsActionability.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Non-fatal diagnostics actionability heuristics for filtering user/environment-dependent errors.
//

import Foundation

public enum MirageDiagnosticsActionability {
    public static func shouldCaptureNonFatal(_ event: MirageDiagnosticsErrorEvent) -> Bool {
        // Always keep fault-level events. Noise filtering only applies to non-fatal errors.
        guard event.severity == .error else { return true }

        guard let metadata = event.metadata else {
            return isLikelyUserDependent(message: event.message, category: event.category) == false
        }

        if isLikelyUserDependent(domain: metadata.domain, code: metadata.code) {
            return false
        }

        return isLikelyUserDependent(message: event.message, category: event.category) == false
    }

    public static func isLikelyUserDependent(error: Error) -> Bool {
        let nsError = error as NSError
        return isLikelyUserDependent(domain: nsError.domain, code: nsError.code)
    }

    private static func isLikelyUserDependent(domain: String, code: Int) -> Bool {
        if domain == NSURLErrorDomain || domain == "kCFErrorDomainCFNetwork" {
            return userDependentURLErrorCodes.contains(code)
        }

        if domain == NSCocoaErrorDomain {
            return userDependentCocoaErrorCodes.contains(code)
        }

        if domain == NSPOSIXErrorDomain {
            return userDependentPOSIXErrorCodes.contains(code)
        }

        if domain == NSOSStatusErrorDomain {
            return userDependentOSStatusErrorCodes.contains(code)
        }

        if domain == MirageRuntimeConditionError.diagnosticsDomain {
            return userDependentRuntimeConditionErrorCodes.contains(code)
        }

        if domain == "Network.NWError" || domain == "NWErrorDomain" {
            return userDependentNWErrorCodes.contains(code)
        }

        if domain == "MirageKit.MirageRemoteSignalingError" {
            return userDependentRemoteSignalingErrorCodes.contains(code)
        }

        if domain == "CKErrorDomain" {
            return userDependentCloudKitErrorCodes.contains(code)
        }
        if domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            return userDependentSCStreamErrorCodes.contains(code)
        }

        return false
    }

    private static func isLikelyUserDependent(message: String, category: LogCategory) -> Bool {
        let normalized = message.lowercased()

        if category == .host {
            for marker in userDependentHostMessageMarkers where normalized.contains(marker) {
                return true
            }
        }

        if category == .appState {
            for marker in userDependentAppStateMessageMarkers where normalized.contains(marker) {
                return true
            }
        }

        if category == .bootstrapHandoff {
            for marker in userDependentBootstrapHandoffMessageMarkers where normalized.contains(marker) {
                return true
            }
        }

        return false
    }

    private static let userDependentURLErrorCodes: Set<Int> = [
        -999, // cancelled
        -1200, // secureConnectionFailed
        -1020, // dataNotAllowed
        -1018, // internationalRoamingOff
        -1012, // userCancelledAuthentication
        -1009, // notConnectedToInternet
        -1006, // dnsLookupFailed
        -1005, // networkConnectionLost
        -1004, // cannotConnectToHost
        -1003, // cannotFindHost
        -1001, // timedOut
    ]

    private static let userDependentCocoaErrorCodes: Set<Int> = [
        4865, // Coder value not found (protocol/version mismatch payloads)
    ]

    private static let userDependentPOSIXErrorCodes: Set<Int> = [
        Int(POSIXErrorCode.ECONNABORTED.rawValue),
        Int(POSIXErrorCode.ECONNRESET.rawValue),
        Int(POSIXErrorCode.ENOTCONN.rawValue),
        Int(POSIXErrorCode.ETIMEDOUT.rawValue),
        Int(POSIXErrorCode.ECANCELED.rawValue),
        Int(POSIXErrorCode.ENETDOWN.rawValue),
        Int(POSIXErrorCode.ENETUNREACH.rawValue),
        Int(POSIXErrorCode.ENETRESET.rawValue),
        Int(POSIXErrorCode.EHOSTUNREACH.rawValue),
        Int(POSIXErrorCode.EPIPE.rawValue),
    ]

    private static let userDependentOSStatusErrorCodes: Set<Int> = [
        -12900, // kVTPropertyNotSupportedErr
        -12909, // kVTVideoDecoderBadDataErr
        -12910, // VideoToolbox decode callback unsupported/reference data mismatch
        -17694, // kVTVideoDecoderReferenceMissingErr
    ]

    private static let userDependentRuntimeConditionErrorCodes: Set<Int> = [
        MirageRuntimeConditionError.sessionLocked.rawValue,
        MirageRuntimeConditionError.waitingForHostApproval.rawValue,
    ]

    private static let userDependentNWErrorCodes: Set<Int> = [
        50, // ENETDOWN
        51, // ENETUNREACH
        52, // ENETRESET
        53, // ECONNABORTED
        54, // ECONNRESET
        57, // ENOTCONN
        60, // ETIMEDOUT
        65, // EHOSTUNREACH
        89, // ECANCELED
    ]

    private static let userDependentRemoteSignalingErrorCodes: Set<Int> = [
        1, // invalidConfiguration
    ]

    private static let userDependentCloudKitErrorCodes: Set<Int> = [
        3, // networkUnavailable
        4, // networkFailure
        6, // serviceUnavailable
        7, // requestRateLimited
        9, // notAuthenticated
    ]

    private static let userDependentSCStreamErrorCodes: Set<Int> = [
        -3808, // Stopping an already-tearing-down stream.
    ]

    private static let userDependentHostMessageMarkers: [String] = [
        "virtual display mode validation failed:",
        "virtual display retina activation failed for profile",
        "virtual display failed retina activation for all descriptor profiles",
        "virtual display failed 1x activation for all descriptor profiles",
        "virtual display acquisition failed for desktop stream; fail-closed policy active:"
    ]

    private static let userDependentAppStateMessageMarkers: [String] = [
        "failed to start desktop stream: protocol error: virtual display acquisition failed",
        "remote signaling paused due configuration/auth failure:",
        "remote signaling close failed: http(statuscode: 401",
        "remote signaling close failed: http(statuscode: 403",
    ]

    private static let userDependentBootstrapHandoffMessageMarkers: [String] = [
        "bootstrap daemon register failed for",
    ]
}
