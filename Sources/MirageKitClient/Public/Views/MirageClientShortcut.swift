//
//  MirageClientShortcut.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Global client shortcut model used by stream UI actions.
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
import Foundation

/// Keyboard shortcut configured for a client-side stream action.
public struct MirageClientShortcut: Codable, Sendable, Hashable {
    /// macOS virtual key code.
    public let keyCode: UInt16
    /// Modifier flags required for the shortcut.
    public let modifiers: MirageInput.MirageModifierFlags

    /// Creates a client shortcut from a virtual key code and modifiers.
    public init(keyCode: UInt16, modifiers: MirageInput.MirageModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Default shortcut for toggling dictation.
    public static let defaultDictationToggle = MirageClientShortcut(
        keyCode: 0x02, // D
        modifiers: [.command, .shift, .option]
    )

    /// Default shortcut for exiting desktop streaming.
    public static let defaultDesktopExit = MirageClientShortcut(
        keyCode: 0x35, // Escape
        modifiers: [.control, .option]
    )

    /// Default shortcut that remaps Escape to a host-safe key combination.
    public static let defaultEscapeRemap = MirageClientShortcut(
        keyCode: 0x21, // [
        modifiers: [.control]
    )

    /// Returns whether a key event matches this shortcut after modifier normalization.
    public func matches(_ keyEvent: MirageInput.MirageKeyEvent) -> Bool {
        keyEvent.keyCode == keyCode &&
            keyEvent.modifiers.normalizedForShortcutMatching == modifiers.normalizedForShortcutMatching
    }

    /// Compact shortcut label using standard modifier glyphs.
    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += MirageInput.MirageClientShortcutBinding.keyName(for: keyCode)
        return result
    }

    #if os(iOS) || os(visionOS)
    func keyDownEvent(isRepeat: Bool = false) -> MirageInput.MirageKeyEvent {
        MirageInput.MirageKeyEvent(
            keyCode: keyCode,
            modifiers: modifiers.normalizedForShortcutMatching,
            isRepeat: isRepeat
        )
    }

    var keyUpEvent: MirageInput.MirageKeyEvent {
        MirageInput.MirageKeyEvent(
            keyCode: keyCode,
            modifiers: modifiers.normalizedForShortcutMatching
        )
    }
    #endif

    /// Display name for a macOS virtual key code.
    public static func keyName(for keyCode: UInt16) -> String {
        MirageInput.MirageClientShortcutBinding.keyName(for: keyCode)
    }
}

// MARK: - MirageInput.MirageClientShortcutBinding Bridge

public extension MirageClientShortcut {
    /// Creates a client shortcut from the shared shortcut-binding model.
    init(_ binding: MirageInput.MirageClientShortcutBinding) {
        self.init(keyCode: binding.keyCode, modifiers: binding.modifiers)
    }

    /// Shared shortcut-binding representation used by host and client preference storage.
    var asBinding: MirageInput.MirageClientShortcutBinding {
        MirageInput.MirageClientShortcutBinding(keyCode: keyCode, modifiers: modifiers)
    }
}

public extension MirageInput.MirageClientShortcutBinding {
    /// Creates a shared shortcut binding from a client shortcut.
    init(_ shortcut: MirageClientShortcut) {
        self.init(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    }
}
