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

        if let metadata = event.metadata {
            return isLikelyUserDependent(domain: metadata.domain, code: metadata.code) == false
        }

        // Legacy fallback for non-typed call sites.
        return isLikelyUserDependentMessage(event.message) == false
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

        if domain == "Network.NWError" || domain == "NWErrorDomain" {
            return userDependentNWErrorCodes.contains(code)
        }

        if domain == "CKErrorDomain" {
            return userDependentCloudKitErrorCodes.contains(code)
        }

        return false
    }

    private static func isLikelyUserDependentMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()

        if normalized.contains("ended by peer/network") {
            return true
        }

        if normalized.contains("network is down")
            || normalized.contains("network is unreachable")
            || normalized.contains("the internet connection appears to be offline")
            || normalized.contains("could not connect to the server")
            || normalized.contains("connection reset by peer")
            || normalized.contains("operation canceled")
            || normalized.contains("operation cancelled")
            || normalized.contains("not connected") {
            return true
        }

        if normalized.contains("remote signaling advertise failed"),
           normalized.contains("auth_failed")
            || normalized.contains("signature_verification_failed")
            || normalized.contains("statuscode: 401")
            || normalized.contains("statuscode: 403")
            || normalized.contains("statuscode: 408")
            || normalized.contains("statuscode: 429") {
            return true
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
        -12909, // kVTVideoDecoderBadDataErr
        -12910, // VideoToolbox decode callback unsupported/reference data mismatch
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
}
