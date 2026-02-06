import MirageKit
#if os(macOS)

//
//  UnlockManager+Polling.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Unlock manager extensions.
//

import AppKit
import CoreGraphics
import Foundation

extension UnlockManager {
    // MARK: - Unlock State Polling

    /// Poll session state until unlock is detected or timeout
    /// This replaces the fixed 1.5s wait with dynamic polling
    func pollForUnlockCompletion(
        timeout: TimeInterval = 25.0,
        pollInterval: TimeInterval = 0.35
    )
    async -> HostSessionState {
        let startTime = Date()
        var lastState = await sessionMonitor.refreshState(notify: false)
        var pollCount = 0

        MirageLogger.host("Starting unlock polling (timeout: \(timeout)s, interval: \(pollInterval)s)")

        while Date().timeIntervalSince(startTime) < timeout {
            try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
            pollCount += 1

            let newState = await sessionMonitor.refreshState(notify: false)

            if newState == .active {
                let elapsed = Date().timeIntervalSince(startTime)
                let elapsedText = elapsed.formatted(.number.precision(.fractionLength(2)))
                MirageLogger.host("Unlock detected after \(elapsedText)s (\(pollCount) polls)")
                return newState
            }

            // Log state changes during polling
            if newState != lastState {
                MirageLogger.host("State changed during unlock polling: \(lastState) -> \(newState)")
                lastState = newState
            }
        }

        MirageLogger.host("Unlock polling timed out after \(timeout)s (\(pollCount) polls), final state: \(lastState)")
        return lastState
    }
}

#endif
