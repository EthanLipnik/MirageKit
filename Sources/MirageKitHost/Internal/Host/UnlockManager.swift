//
//  UnlockManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/7/26.
//

import CoreGraphics
import Foundation
import Security
import MirageKit

#if os(macOS)
import Carbon.HIToolbox
import IOKit.pwr_mgt

// Private SkyLight functions for session management - loaded dynamically at runtime
// These are used by loginwindow and other system components
// Using dlsym instead of @_silgen_name to avoid linker errors with private symbols

/// Dynamically call SLSSessionSwitchToUser from the private SkyLight framework
/// Returns 0 on success, non-zero on failure, or nil if the function isn't available
func callSLSSessionSwitchToUser(_ username: String) -> Int32? {
    // Get handle to SkyLight framework
    guard let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
    defer { dlclose(skylight) }

    // Get function pointer
    guard let sym = dlsym(skylight, "SLSSessionSwitchToUser") else { return nil }

    // Cast to function type and call
    typealias SLSSessionSwitchToUserFunc = @convention(c) (UnsafePointer<CChar>) -> Int32
    let functionPointer = unsafeBitCast(sym, to: SLSSessionSwitchToUserFunc.self)

    return username.withCString { usernamePtr in
        functionPointer(usernamePtr)
    }
}

/// Manages programmatic unlock for locked Macs using Authorization Services
/// Verifies credentials via PAM/Authorization and attempts to unlock the session
actor UnlockManager {
    /// Result of an unlock attempt
    enum UnlockResult: Equatable {
        case success
        case failure(UnlockErrorCode, String)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }

        var error: UnlockError? {
            if case let .failure(code, message) = self { return UnlockError(code: code, message: message) }
            return nil
        }

        var canRetry: Bool {
            if case let .failure(code, _) = self { return code != .rateLimited && code != .notAuthorized }
            return false
        }
    }

    /// Session state monitor for verifying unlock success
    let sessionMonitor: SessionStateMonitor

    /// Rate limiting: track attempts per client
    var attemptsByClient: [UUID: [Date]] = [:]

    /// Maximum attempts per window
    let maxAttempts = 5

    /// Rate limit window in seconds
    let rateLimitWindow: TimeInterval = 300 // 5 minutes

    /// Power assertion ID for keeping display awake
    var powerAssertionID: IOPMAssertionID = 0

    init(sessionMonitor: SessionStateMonitor) {
        self.sessionMonitor = sessionMonitor
    }
}

#endif
