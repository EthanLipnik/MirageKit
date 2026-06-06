//
//  AppStreamManager+WindowStartupRetries.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Window startup retry bookkeeping for app-stream sessions.
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
#if os(macOS)
import Foundation

struct AppStreamWindowStartupFailureState {
    /// Number of consecutive failed startup attempts for the window.
    var failureCount: Int = 0
    /// Earliest time at which another startup attempt may run.
    var nextRetryAt: Date = .distantPast
    /// Whether the terminal failure has already been reported to callers.
    var terminalNoticeSent: Bool = false
}

enum AppStreamWindowStartupFailureDisposition: Equatable {
    /// A retry is allowed after the returned backoff deadline.
    case retryScheduled(attempt: Int, retryAt: Date)
    /// The window exhausted its startup attempts and should be reported once.
    case terminal(attempt: Int)
    /// The terminal failure was already reported and should stay quiet.
    case suppressed
}

extension AppStreamManager {
    private static let maxWindowStartupAttempts = 3

    private static let windowStartupRetryBackoffSeconds: [TimeInterval] = [0.35, 1.0, 2.0]

    /// Returns whether the retry state currently permits another startup attempt for a window.
    func canAttemptWindowStartup(
        bundleID: String,
        windowID: WindowID,
        now: Date = Date()
    ) -> Bool {
        let normalizedBundleID = appSessionKey(for: bundleID)
        guard let state = startupFailureStateByBundleID[normalizedBundleID]?[windowID] else { return true }
        guard state.failureCount < Self.maxWindowStartupAttempts else { return false }
        return now >= state.nextRetryAt
    }

    /// Records a failed window startup attempt and returns the action the caller should take.
    func noteWindowStartupFailed(
        bundleID: String,
        windowID: WindowID,
        retryable: Bool,
        now: Date = Date()
    ) -> AppStreamWindowStartupFailureDisposition {
        let normalizedBundleID = appSessionKey(for: bundleID)
        var windowStates = startupFailureStateByBundleID[normalizedBundleID] ?? [:]
        var state = windowStates[windowID] ?? AppStreamWindowStartupFailureState()

        if state.failureCount >= Self.maxWindowStartupAttempts {
            if state.terminalNoticeSent {
                windowStates[windowID] = state
                startupFailureStateByBundleID[normalizedBundleID] = windowStates
                return .suppressed
            }
            state.terminalNoticeSent = true
            windowStates[windowID] = state
            startupFailureStateByBundleID[normalizedBundleID] = windowStates
            return .terminal(attempt: state.failureCount)
        }

        if retryable {
            state.failureCount += 1
            if state.failureCount < Self.maxWindowStartupAttempts {
                let backoffIndex = min(state.failureCount - 1, Self.windowStartupRetryBackoffSeconds.count - 1)
                let retryAt = now.addingTimeInterval(Self.windowStartupRetryBackoffSeconds[backoffIndex])
                state.nextRetryAt = retryAt
                windowStates[windowID] = state
                startupFailureStateByBundleID[normalizedBundleID] = windowStates
                return .retryScheduled(attempt: state.failureCount, retryAt: retryAt)
            }
        } else {
            state.failureCount = Self.maxWindowStartupAttempts
        }

        state.nextRetryAt = .distantFuture
        if !state.terminalNoticeSent {
            state.terminalNoticeSent = true
            windowStates[windowID] = state
            startupFailureStateByBundleID[normalizedBundleID] = windowStates
            return .terminal(attempt: state.failureCount)
        }

        windowStates[windowID] = state
        startupFailureStateByBundleID[normalizedBundleID] = windowStates
        return .suppressed
    }

    /// Records a startup failure when the caller does not need the resulting disposition.
    func recordWindowStartupFailure(
        bundleID: String,
        windowID: WindowID,
        retryable: Bool,
        now: Date = Date()
    ) {
        _ = noteWindowStartupFailed(
            bundleID: bundleID,
            windowID: windowID,
            retryable: retryable,
            now: now
        )
    }

    /// Clears retry state after a window successfully attaches to a stream.
    func noteWindowStartupSucceeded(bundleID: String, windowID: WindowID) {
        clearWindowStartupTracking(bundleID: bundleID, windowID: windowID)
    }

    /// Removes retry state for one window and prunes the bundle entry when it becomes empty.
    func clearWindowStartupTracking(bundleID: String, windowID: WindowID) {
        let normalizedBundleID = appSessionKey(for: bundleID)
        guard var windowStates = startupFailureStateByBundleID[normalizedBundleID] else { return }
        windowStates.removeValue(forKey: windowID)
        if windowStates.isEmpty {
            startupFailureStateByBundleID.removeValue(forKey: normalizedBundleID)
        } else {
            startupFailureStateByBundleID[normalizedBundleID] = windowStates
        }
    }
}

#endif
