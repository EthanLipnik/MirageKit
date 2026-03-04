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

        guard let metadata = event.metadata else { return true }
        return isLikelyUserDependent(domain: metadata.domain, code: metadata.code) == false
    }

    public static func isLikelyUserDependent(error: Error) -> Bool {
        let nsError = error as NSError
        return isLikelyUserDependent(domain: nsError.domain, code: nsError.code)
    }

    private static func isLikelyUserDependent(domain: String, code: Int) -> Bool {
        if domain == NSURLErrorDomain || domain == "kCFErrorDomainCFNetwork" {
            return userDependentURLErrorCodes.contains(code)
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

        if domain == "CKErrorDomain" {
            return userDependentCloudKitErrorCodes.contains(code)
        }
        if domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            return userDependentSCStreamErrorCodes.contains(code)
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
}
