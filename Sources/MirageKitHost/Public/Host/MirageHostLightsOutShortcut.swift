//
//  MirageHostLightsOutShortcut.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//
//  Host Lights Out emergency shortcut defaults and validation.
//

import MirageKit

#if os(macOS)
/// Default shortcut and validation helpers for the host Lights Out emergency control.
public enum MirageHostLightsOutShortcut {
    /// Default emergency shortcut: Control-Option-Escape.
    public static let defaultEmergencyShortcut = MirageClientShortcutBinding(
        keyCode: 0x35,
        modifiers: [.control, .option]
    )

    /// Returns a validation error when the shortcut cannot safely trigger Lights Out.
    public static func validationError(
        for shortcut: MirageClientShortcutBinding
    ) -> MirageHostLightsOutShortcutValidationError? {
        let normalizedModifiers = shortcut.modifiers.normalizedForShortcutMatching
        if normalizedModifiers.isEmpty {
            return .modifierRequired
        }

        if modifierOnlyKeyCodes.contains(shortcut.keyCode) {
            return .nonModifierKeyRequired
        }

        return nil
    }

    /// Normalizes shortcut modifiers before storage or comparison.
    public static func normalized(
        _ shortcut: MirageClientShortcutBinding
    ) -> MirageClientShortcutBinding {
        MirageClientShortcutBinding(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers.normalizedForShortcutMatching
        )
    }

    private static let modifierOnlyKeyCodes: Set<UInt16> = [
        0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
    ]
}

/// Validation errors for the host Lights Out emergency shortcut.
public enum MirageHostLightsOutShortcutValidationError: LocalizedError, Equatable, Sendable {
    /// The shortcut must include at least one modifier key.
    case modifierRequired
    /// The shortcut must include a non-modifier key.
    case nonModifierKeyRequired

    /// User-facing validation message.
    public var errorDescription: String? {
        switch self {
        case .modifierRequired:
            "Choose a shortcut with at least one modifier."
        case .nonModifierKeyRequired:
            "Choose a shortcut with a non-modifier key."
        }
    }
}
#endif
