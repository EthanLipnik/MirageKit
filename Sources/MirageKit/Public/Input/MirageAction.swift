//
//  MirageAction.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/6/26.
//

import Foundation

/// Where a triggered action is handled.
public enum MirageActionTarget: String, Codable, Sendable, Hashable {
    /// Handled client-side (e.g. dictation toggle, escape remap).
    case local
    /// Sends a synthetic key event to the host via CGEvent injection.
    case hostKeyInject
}

/// A unified client action that can be triggered by keyboard shortcuts,
/// the stream control bar, or gestures.
public struct MirageAction: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public var displayName: String
    public var target: MirageActionTarget
    /// The key combo to inject on the host (only used for `.hostKeyInject`).
    public var hostKeyEvent: MirageKeyEvent?
    /// Client-side keyboard shortcut that triggers this action.
    public var shortcut: MirageClientShortcutBinding?
    /// Whether this action appears in the floating stream control bar.
    public var showInControlBar: Bool
    /// Built-in actions cannot be deleted, only customized.
    public var isBuiltIn: Bool
    /// SF Symbol name for the control bar icon.
    public var sfSymbolName: String?

    public init(
        id: String,
        displayName: String,
        target: MirageActionTarget,
        hostKeyEvent: MirageKeyEvent? = nil,
        shortcut: MirageClientShortcutBinding? = nil,
        showInControlBar: Bool = false,
        isBuiltIn: Bool = true,
        sfSymbolName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.target = target
        self.hostKeyEvent = hostKeyEvent
        self.shortcut = shortcut
        self.showInControlBar = showInControlBar
        self.isBuiltIn = isBuiltIn
        self.sfSymbolName = sfSymbolName
    }
}

/// Keyboard shortcut binding used by ``MirageAction``.
///
/// This is a standalone binding type that stores a key code and modifier flags
/// without coupling to UIKit or AppKit.
public struct MirageClientShortcutBinding: Codable, Sendable, Hashable {
    public let keyCode: UInt16
    public let modifiers: MirageModifierFlags

    public init(keyCode: UInt16, modifiers: MirageModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Whether this binding matches a given key event.
    public func matches(_ keyEvent: MirageKeyEvent) -> Bool {
        keyEvent.keyCode == keyCode &&
            Self.normalizedModifiers(keyEvent.modifiers) == Self.normalizedModifiers(modifiers)
    }

    /// Strips non-shortcut modifiers (caps lock, numeric pad, function).
    public static func normalizedModifiers(_ flags: MirageModifierFlags) -> MirageModifierFlags {
        var normalized: MirageModifierFlags = []
        if flags.contains(.command) { normalized.insert(.command) }
        if flags.contains(.shift) { normalized.insert(.shift) }
        if flags.contains(.option) { normalized.insert(.option) }
        if flags.contains(.control) { normalized.insert(.control) }
        return normalized
    }

    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    private static let keyNames: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
        0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
        0x21: "[", 0x22: "I", 0x23: "P", 0x24: "↩", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
        0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "⇥",
        0x31: "Space", 0x32: "`", 0x33: "⌫", 0x35: "⎋", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]

    public static func keyName(for keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }
}

// MARK: - Built-In Action Identifiers

public extension MirageAction {
    static let spaceLeftID = "spaceLeft"
    static let spaceRightID = "spaceRight"
    static let missionControlID = "missionControl"
    static let appExposeID = "appExpose"
    static let cmdTabID = "cmdTab"
    static let dictationToggleID = "dictationToggle"
    static let escapeRemapID = "escapeRemap"
}

// MARK: - Built-In Actions

public extension MirageAction {
    static let spaceLeft = MirageAction(
        id: spaceLeftID,
        displayName: "Switch Space Left",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x7B, modifiers: .control),
        showInControlBar: true,
        sfSymbolName: "chevron.left"
    )

    static let spaceRight = MirageAction(
        id: spaceRightID,
        displayName: "Switch Space Right",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x7C, modifiers: .control),
        showInControlBar: true,
        sfSymbolName: "chevron.right"
    )

    static let missionControl = MirageAction(
        id: missionControlID,
        displayName: "Mission Control",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x7E, modifiers: .control),
        showInControlBar: true,
        sfSymbolName: "rectangle.3.group"
    )

    static let appExpose = MirageAction(
        id: appExposeID,
        displayName: "App Exposé",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x7D, modifiers: .control),
        showInControlBar: true,
        sfSymbolName: "squares.below.rectangle"
    )

    static let cmdTab = MirageAction(
        id: cmdTabID,
        displayName: "App Switcher",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x30, modifiers: .command),
        showInControlBar: true,
        sfSymbolName: "command"
    )

    static let dictationToggle = MirageAction(
        id: dictationToggleID,
        displayName: "Toggle Dictation",
        target: .local,
        shortcut: MirageClientShortcutBinding(keyCode: 0x02, modifiers: [.command, .shift, .option])
    )

    static let escapeRemap = MirageAction(
        id: escapeRemapID,
        displayName: "Escape Remap",
        target: .local,
        shortcut: MirageClientShortcutBinding(keyCode: 0x21, modifiers: .control)
    )

    static let allBuiltIn: [MirageAction] = [
        .spaceLeft, .spaceRight, .missionControl, .appExpose, .cmdTab,
        .dictationToggle, .escapeRemap,
    ]
}
