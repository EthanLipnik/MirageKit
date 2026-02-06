//
//  MirageHostInputController+StuckModifiers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Stuck Modifier Detection

    func startModifierResetTimerIfNeeded() {
        guard modifierResetTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: accessibilityQueue)
        timer.schedule(
            deadline: .now() + modifierResetPollIntervalSeconds,
            repeating: modifierResetPollIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            self?.checkForStuckModifiers()
        }
        timer.resume()
        modifierResetTimer = timer
    }

    func stopModifierResetTimer() {
        modifierResetTimer?.cancel()
        modifierResetTimer = nil
    }

    private func checkForStuckModifiers() {
        let now = CACurrentMediaTime()
        var stuckModifiers: MirageModifierFlags = []

        // Check each active modifier individually for staleness
        for (flag, timestamp) in modifierLastEventTimes {
            if now - timestamp > modifierStuckTimeoutSeconds { stuckModifiers.insert(flag) }
        }

        if !stuckModifiers.isEmpty {
            MirageLogger.host("Clearing stuck modifiers: \(stuckModifiers)")
            let remainingModifiers = lastSentModifiers.subtracting(stuckModifiers)
            injectFlagsChanged(remainingModifiers, app: nil)
        }

        // Also verify system state matches tracked state
        clearUnexpectedSystemModifiers()
    }

    /// Query the actual system modifier state and clear any modifiers that shouldn't be there.
    func clearUnexpectedSystemModifiers() {
        let systemFlags = CGEventSource.flagsState(.hidSystemState)

        var actualModifiers: MirageModifierFlags = []
        for (cgFlag, mirageFlag) in Self.cgFlagToMirageFlag {
            if systemFlags.contains(cgFlag) { actualModifiers.insert(mirageFlag) }
        }

        if !actualModifiers.isEmpty, lastSentModifiers.isEmpty {
            MirageLogger.host("Clearing unexpected system modifiers: \(actualModifiers)")

            for (flag, keyCode) in Self.modifierKeyCodes where actualModifiers.contains(flag) {
                if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                    keyEvent.flags = actualModifiers.cgEventFlags
                    postEvent(keyEvent)
                }
                actualModifiers.remove(flag)
            }

            if let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                cgEvent.type = .flagsChanged
                cgEvent.flags = []
                postEvent(cgEvent)
            }
        }
    }

    /// Clear all modifier state.
    /// - Note: Call when starting a new stream or reconnecting to avoid stuck modifiers.
    public func clearAllModifiers() {
        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            guard !lastSentModifiers.isEmpty || !heldModifierKeyCodes.isEmpty else { return }

            MirageLogger.host("Clearing all modifiers on session change")

            for keyCode in heldModifierKeyCodes {
                if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                    keyEvent.flags = []
                    postEvent(keyEvent)
                }
            }
            heldModifierKeyCodes.removeAll()

            if let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                cgEvent.type = .flagsChanged
                cgEvent.flags = []
                postEvent(cgEvent)
            }

            lastSentModifiers = []
            modifierLastEventTimes.removeAll()
            stopModifierResetTimer()
        }
    }
}

#endif
