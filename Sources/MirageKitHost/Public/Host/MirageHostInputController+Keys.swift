//
//  MirageHostInputController+Keys.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
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
import CoreGraphics

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Key Event Injection (runs on accessibilityQueue)

    /// Keyboard event values used to build a CoreGraphics event.
    struct KeyboardInjectionPlan: Equatable {
        let virtualKey: CGKeyCode
        let unicodeString: String?
    }

    /// Resolves the virtual key or Unicode fallback needed for a key event.
    static func keyboardInjectionPlan(for event: MirageInput.MirageKeyEvent) -> KeyboardInjectionPlan {
        guard event.usesUnicodeScalarFallback else {
            return KeyboardInjectionPlan(
                virtualKey: CGKeyCode(event.keyCode),
                unicodeString: nil
            )
        }

        let unicodeString: String? = if let characters = event.characters, !characters.isEmpty {
            characters
        } else {
            nil
        }

        return KeyboardInjectionPlan(
            virtualKey: 0,
            unicodeString: unicodeString
        )
    }

    /// Builds a CoreGraphics keyboard event with Mirage modifiers and repeat state applied.
    func makeInjectedKeyboardEvent(
        isKeyDown: Bool,
        _ event: MirageInput.MirageKeyEvent
    ) -> CGEvent? {
        let injectionPlan = Self.keyboardInjectionPlan(for: event)
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: injectionPlan.virtualKey,
            keyDown: isKeyDown
        ) else {
            return nil
        }

        cgEvent.flags = event.modifiers.cgEventFlags
        if let unicodeString = injectionPlan.unicodeString {
            let unicodeScalars = Array(unicodeString.utf16)
            cgEvent.keyboardSetUnicodeString(
                stringLength: unicodeScalars.count,
                unicodeString: unicodeScalars
            )
        }

        if event.isRepeat {
            cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }

        return cgEvent
    }

    /// Injects a key-down or key-up event into the requested host event domain.
    func injectKeyEvent(
        isKeyDown: Bool,
        _ event: MirageInput.MirageKeyEvent,
        domain: HostKeyboardInjectionDomain
    ) {
        guard let cgEvent = makeInjectedKeyboardEvent(isKeyDown: isKeyDown, event) else { return }

        HostKeyboardInputDiagnostics.logPost(
            keyEvent: event,
            isKeyDown: isKeyDown,
            domain: domain
        )
        postEvent(cgEvent, domain: domain)

        let trackedModifiers = event.modifiers.intersection(lastSentModifiers)
        if !trackedModifiers.isEmpty {
            let now = CACurrentMediaTime()
            for (flag, _) in Self.modifierKeyCodes where trackedModifiers.contains(flag) {
                modifierLastEventTimes[flag] = now
            }
        }

        if !isKeyDown, !event.modifiers.isEmpty {
            clearUnexpectedSystemModifiers(domain: domain)
        }
    }

    /// Injects modifier key transitions needed to reach the requested modifier state.
    func injectFlagsChanged(
        _ modifiers: MirageInput.MirageModifierFlags,
        domain: HostKeyboardInjectionDomain
    ) {
        let transitionPlan = Self.modifierTransitionPlan(from: lastSentModifiers, to: modifiers)
        HostKeyboardInputDiagnostics.logPost(
            modifiers: modifiers,
            domain: domain
        )

        var cumulativeFlags = lastSentModifiers
        for (flag, keyCode) in Self.modifierKeyCodes where transitionPlan.pressed.contains(keyCode) {
            cumulativeFlags.insert(flag)
            if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
                keyEvent.flags = cumulativeFlags.cgEventFlags
                postEvent(keyEvent, domain: domain)
                heldModifierKeyCodes.insert(keyCode)
            }
        }

        var releaseFlags = cumulativeFlags
        for (flag, keyCode) in Self.modifierKeyCodes where transitionPlan.released.contains(keyCode) {
            // Remove flag BEFORE posting so the event flags reflect the post-release state.
            // When physically releasing a key, macOS expects the key-up event to NOT contain
            // the modifier being released (e.g., releasing Command should have empty flags).
            releaseFlags.remove(flag)
            if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                keyEvent.flags = releaseFlags.cgEventFlags
                postEvent(keyEvent, domain: domain)
                heldModifierKeyCodes.remove(keyCode)
            }
        }

        postFlagsChangedEvent(modifiers, domain: domain)

        lastModifierInjectionDomain = domain
        lastSentModifiers = modifiers

        let now = CACurrentMediaTime()
        for (flag, _) in Self.modifierKeyCodes where modifiers.contains(flag) {
            modifierLastEventTimes[flag] = now
        }
        for (flag, _) in Self.modifierKeyCodes where !modifiers.contains(flag) {
            modifierLastEventTimes.removeValue(forKey: flag)
        }

        if !modifiers.isEmpty { startModifierResetTimerIfNeeded() } else {
            stopModifierResetTimer()
        }
    }
}

#endif
