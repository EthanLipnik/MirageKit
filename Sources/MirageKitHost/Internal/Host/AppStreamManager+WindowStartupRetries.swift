//
//  AppStreamManager+WindowStartupRetries.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Window startup retry bookkeeping for app-stream sessions.
//

import MirageKit
#if os(macOS)
import Foundation

struct AppStreamWindowStartupFailureState: Sendable {
    var failureCount: Int = 0
    var nextRetryAt: Date = .distantPast
    var terminalNoticeSent: Bool = false
    var lastReason: String = ""
}

enum AppStreamWindowStartupFailureDisposition: Sendable, Equatable {
    case retryScheduled(attempt: Int, retryAt: Date)
    case terminal(attempt: Int)
    case suppressed
}

extension AppStreamManager {
    private var maxWindowStartupAttempts: Int { 3 }

    private var windowStartupRetryBackoffSeconds: [TimeInterval] {
        [0.35, 1.0, 2.0]
    }

    func canAttemptWindowStartup(
        bundleID: String,
        windowID: WindowID,
        now: Date = Date()
    ) -> Bool {
        let normalizedBundleID = bundleID.lowercased()
        guard let state = startupFailureStateByBundleID[normalizedBundleID]?[windowID] else { return true }
        guard state.failureCount < maxWindowStartupAttempts else { return false }
        return now >= state.nextRetryAt
    }

    @discardableResult
    func noteWindowStartupFailed(
        bundleID: String,
        windowID: WindowID,
        retryable: Bool,
        reason: String,
        now: Date = Date()
    ) -> AppStreamWindowStartupFailureDisposition {
        let normalizedBundleID = bundleID.lowercased()
        var windowStates = startupFailureStateByBundleID[normalizedBundleID] ?? [:]
        var state = windowStates[windowID] ?? AppStreamWindowStartupFailureState()
        state.lastReason = reason

        if state.failureCount >= maxWindowStartupAttempts {
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
            if state.failureCount < maxWindowStartupAttempts {
                let backoffIndex = min(state.failureCount - 1, windowStartupRetryBackoffSeconds.count - 1)
                let retryAt = now.addingTimeInterval(windowStartupRetryBackoffSeconds[backoffIndex])
                state.nextRetryAt = retryAt
                windowStates[windowID] = state
                startupFailureStateByBundleID[normalizedBundleID] = windowStates
                return .retryScheduled(attempt: state.failureCount, retryAt: retryAt)
            }
        } else {
            state.failureCount = maxWindowStartupAttempts
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

    func noteWindowStartupSucceeded(bundleID: String, windowID: WindowID) {
        clearWindowStartupTracking(bundleID: bundleID, windowID: windowID)
    }

    func clearWindowStartupTracking(bundleID: String, windowID: WindowID) {
        let normalizedBundleID = bundleID.lowercased()
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
