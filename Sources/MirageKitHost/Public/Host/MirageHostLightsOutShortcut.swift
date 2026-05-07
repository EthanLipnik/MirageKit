//
//  MirageHostLightsOutShortcut.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//
//  Host Lights Out emergency shortcut defaults and validation.
//

import Foundation
import MirageKit

#if os(macOS)
public enum MirageHostLightsOutShortcut {
    public static let defaultEmergencyShortcut = MirageClientShortcutBinding(
        keyCode: 0x35,
        modifiers: [.control, .option]
    )

    public static func validationError(
        for shortcut: MirageClientShortcutBinding
    ) -> MirageHostLightsOutShortcutValidationError? {
        let normalizedModifiers = MirageClientShortcutBinding.normalizedModifiers(shortcut.modifiers)
        if normalizedModifiers.isEmpty {
            return .modifierRequired
        }

        if modifierOnlyKeyCodes.contains(shortcut.keyCode) {
            return .nonModifierKeyRequired
        }

        return nil
    }

    public static func normalized(
        _ shortcut: MirageClientShortcutBinding
    ) -> MirageClientShortcutBinding {
        MirageClientShortcutBinding(
            keyCode: shortcut.keyCode,
            modifiers: MirageClientShortcutBinding.normalizedModifiers(shortcut.modifiers)
        )
    }

    private static let modifierOnlyKeyCodes: Set<UInt16> = [
        0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
    ]
}

public enum MirageHostLightsOutShortcutValidationError: LocalizedError, Equatable, Sendable {
    case modifierRequired
    case nonModifierKeyRequired

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
