//
//  MirageHostInputController+Keys.swift
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
    // MARK: - Key Event Injection (runs on accessibilityQueue)

    func injectKeyEvent(
        isKeyDown: Bool,
        _ event: MirageKeyEvent,
        domain: HostKeyboardInjectionDomain,
        app _: MirageApplication?
    ) {
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(event.keyCode),
            keyDown: isKeyDown
        ) else {
            return
        }

        cgEvent.flags = event.modifiers.cgEventFlags

        if event.isRepeat { cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }

        postEvent(cgEvent, domain: domain)

        // Refresh timestamps only for modifiers tracked via flagsChanged state.
        // Shortcut key events can carry temporary modifier flags without implying
        // a durable held-modifier transition on the host.
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

    func injectFlagsChanged(
        _ modifiers: MirageModifierFlags,
        domain: HostKeyboardInjectionDomain,
        app _: MirageApplication?
    ) {
        let transitionPlan = Self.modifierTransitionPlan(from: lastSentModifiers, to: modifiers)

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

        // Update per-modifier timestamps
        let now = CACurrentMediaTime()
        for (flag, _) in Self.modifierKeyCodes where modifiers.contains(flag) {
            modifierLastEventTimes[flag] = now
        }
        // Remove timestamps for released modifiers
        for (flag, _) in Self.modifierKeyCodes where !modifiers.contains(flag) {
            modifierLastEventTimes.removeValue(forKey: flag)
        }

        if !modifiers.isEmpty { startModifierResetTimerIfNeeded() } else {
            stopModifierResetTimer()
        }
    }

}

#endif
