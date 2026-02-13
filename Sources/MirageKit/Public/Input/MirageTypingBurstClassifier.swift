//
//  MirageTypingBurstClassifier.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Shared classifier for text-entry key events that should trigger latency boosts.
//

import Foundation

package enum MirageTypingBurstClassifier {
    private static let shortcutModifiers: MirageModifierFlags = [.command, .option, .control]
    private static let editingKeyCodes: Set<UInt16> = [
        0x24, // Return
        0x30, // Tab
        0x33, // Delete (backspace)
        0x4C, // Keypad Enter
        0x73, // Home
        0x74, // Page Up
        0x75, // Forward Delete
        0x77, // End
        0x79, // Page Down
        0x7B, // Left Arrow
        0x7C, // Right Arrow
        0x7D, // Down Arrow
        0x7E, // Up Arrow
    ]

    package static func shouldTrigger(for event: MirageInputEvent) -> Bool {
        guard case let .keyDown(keyEvent) = event else { return false }
        return shouldTrigger(for: keyEvent)
    }

    package static func shouldTrigger(for keyEvent: MirageKeyEvent) -> Bool {
        guard !keyEvent.modifiers.containsAny(shortcutModifiers) else { return false }
        if let characters = keyEvent.charactersIgnoringModifiers, !characters.isEmpty { return true }
        return editingKeyCodes.contains(keyEvent.keyCode)
    }
}

private extension MirageModifierFlags {
    func containsAny(_ flags: MirageModifierFlags) -> Bool {
        !intersection(flags).isEmpty
    }
}
