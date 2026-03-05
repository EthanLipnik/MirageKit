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
            injectFlagsChanged(
                remainingModifiers,
                domain: lastModifierInjectionDomain,
                app: nil
            )
        }

        // Also verify system state matches tracked state
        clearUnexpectedSystemModifiers(domain: lastModifierInjectionDomain)
    }

    /// Query the actual system modifier state and clear any modifiers that shouldn't be there.
    func clearUnexpectedSystemModifiers(domain: HostKeyboardInjectionDomain) {
        let systemFlags = CGEventSource.flagsState(Self.systemStateSource(for: domain))

        var actualModifiers: MirageModifierFlags = []
        for (cgFlag, mirageFlag) in Self.cgFlagToMirageFlag {
            if systemFlags.contains(cgFlag) { actualModifiers.insert(mirageFlag) }
        }

        let unexpectedModifiers = actualModifiers.subtracting(lastSentModifiers)
        guard !unexpectedModifiers.isEmpty else { return }

        MirageLogger.host("Clearing unexpected system modifiers: \(unexpectedModifiers)")

        for (flag, keyCodes) in Self.modifierRecoveryKeyCodes where unexpectedModifiers.contains(flag) {
            // Remove the flag before posting key-up so the event reflects the
            // post-release modifier state.
            actualModifiers.remove(flag)
            for keyCode in keyCodes {
                if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                    keyEvent.flags = actualModifiers.cgEventFlags
                    postEvent(keyEvent, domain: domain)
                }
                heldModifierKeyCodes.remove(keyCode)
            }
            modifierLastEventTimes.removeValue(forKey: flag)
        }

        postFlagsChangedEvent(lastSentModifiers, domain: domain)
    }

    /// Clear all modifier state.
    /// - Note: Call when starting a new stream or reconnecting to avoid stuck modifiers.
    public func clearAllModifiers() {
        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            MirageLogger.host("Clearing all modifiers on session change")

            for domain in HostKeyboardInjectionDomain.allCases {
                for keyCode in Self.allModifierRecoveryKeyCodes {
                    if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                        keyEvent.flags = []
                        postEvent(keyEvent, domain: domain)
                    }
                }
                postFlagsChangedEvent([], domain: domain)
            }
            heldModifierKeyCodes.removeAll()

            lastSentModifiers = []
            lastModifierInjectionDomain = .session
            modifierLastEventTimes.removeAll()
            stopModifierResetTimer()
        }
    }
}

#endif
