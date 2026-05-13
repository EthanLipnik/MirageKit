//
//  MirageHostInputController+StuckModifiers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import CoreGraphics
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Stuck Modifier Detection

    /// Starts polling for modifier state that has become stuck on the host.
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

    /// Stops the stuck-modifier polling timer.
    func stopModifierResetTimer() {
        modifierResetTimer?.cancel()
        modifierResetTimer = nil
    }

    /// Releases tracked modifiers that have not received fresh events before the timeout.
    private func checkForStuckModifiers() {
        let now = CACurrentMediaTime()
        var stuckModifiers: MirageModifierFlags = []

        for (flag, timestamp) in modifierLastEventTimes {
            if now - timestamp > modifierStuckTimeoutSeconds { stuckModifiers.insert(flag) }
        }

        if !stuckModifiers.isEmpty {
            MirageLogger.host("Clearing stuck modifiers: \(stuckModifiers)")
            let remainingModifiers = lastSentModifiers.subtracting(stuckModifiers)
            injectFlagsChanged(
                remainingModifiers,
                domain: lastModifierInjectionDomain
            )
        }

        clearUnexpectedSystemModifiers(domain: lastModifierInjectionDomain)
    }

    /// Queries actual system modifier state and clears modifiers Mirage is not tracking as held.
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

    /// Clears all tracked and host-observed modifier state.
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
