//
//  MirageAction.swift
//  MirageInput
//
//  Created by Ethan Lipnik on 6/5/26.
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
/// stream options, or gestures.
public struct MirageAction: Codable, Sendable, Identifiable, Hashable {
    /// Stable action identifier used for persistence and shortcut matching.
    public let id: String

    /// User-facing action title.
    public var displayName: String

    /// Where the action should execute when triggered.
    public var target: MirageActionTarget

    /// The key combo to inject on the host (only used for `.hostKeyInject`).
    public var hostKeyEvent: MirageKeyEvent?

    /// Client-side keyboard shortcut that triggers this action.
    public var shortcut: MirageClientShortcutBinding?

    /// Built-in actions cannot be deleted, only customized.
    public var isBuiltIn: Bool

    /// Whether this action can currently be triggered by its client shortcut.
    public var isEnabled: Bool

    /// SF Symbol name for action UI.
    public var sfSymbolName: String?

    /// Creates a client action definition.
    public init(
        id: String,
        displayName: String,
        target: MirageActionTarget,
        hostKeyEvent: MirageKeyEvent? = nil,
        shortcut: MirageClientShortcutBinding? = nil,
        isBuiltIn: Bool = true,
        isEnabled: Bool = true,
        sfSymbolName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.target = target
        self.hostKeyEvent = hostKeyEvent
        self.shortcut = shortcut
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
        self.sfSymbolName = sfSymbolName
    }
}

public extension MirageAction {
    /// Coding keys for persisted action preferences.
    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case target
        case hostKeyEvent
        case shortcut
        case isBuiltIn
        case isEnabled
        case sfSymbolName
    }

    /// Decodes an action while preserving defaults for older preference payloads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        target = try container.decode(MirageActionTarget.self, forKey: .target)
        hostKeyEvent = try container.decodeIfPresent(MirageKeyEvent.self, forKey: .hostKeyEvent)
        shortcut = try container.decodeIfPresent(MirageClientShortcutBinding.self, forKey: .shortcut)
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? true
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sfSymbolName = try container.decodeIfPresent(String.self, forKey: .sfSymbolName)
    }
}

/// Keyboard shortcut binding used by ``MirageAction``.
///
/// This is a standalone binding type that stores a key code and modifier flags
/// without coupling to UIKit or AppKit.
public struct MirageClientShortcutBinding: Codable, Sendable, Hashable {
    /// Hardware-independent key code for the shortcut trigger.
    public let keyCode: UInt16

    /// Modifier flags required for the shortcut trigger.
    public let modifiers: MirageModifierFlags

    /// Creates a shortcut binding from a key code and modifier set.
    public init(keyCode: UInt16, modifiers: MirageModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Whether this binding matches a given key event.
    public func matches(_ keyEvent: MirageKeyEvent) -> Bool {
        keyEvent.keyCode == keyCode &&
            keyEvent.modifiers.normalizedForShortcutMatching == modifiers.normalizedForShortcutMatching
    }

    /// Human-readable shortcut label such as `S` or `P` with modifier symbols.
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

    /// Returns a compact display name for a macOS virtual key code.
    public static func keyName(for keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }
}

public extension MirageAction {
    /// Whether this action injects a custom host key binding.
    var isCustomHostKeyBinding: Bool {
        target == .hostKeyInject && !isBuiltIn
    }

    /// Whether this built-in action exposes a host-key shortcut in settings.
    var isBuiltInHostKeyShortcut: Bool {
        isBuiltIn && target == .hostKeyInject && shortcut != nil
    }

    /// Human-readable mapping from the local trigger to the host key event.
    var hostKeyBindingSummary: String {
        let source = shortcut?.displayString ?? "Unassigned"
        guard let hostKeyEvent else {
            return "\(source) → Unassigned"
        }

        let target = MirageClientShortcutBinding(
            keyCode: hostKeyEvent.keyCode,
            modifiers: hostKeyEvent.modifiers
        )
        .displayString
        return "\(source) → \(target)"
    }

    /// Creates a custom action that injects a key combination on the remote host.
    static func customHostKeyBinding(
        id: String,
        displayName: String,
        hostKeyEvent: MirageKeyEvent,
        shortcut: MirageClientShortcutBinding? = nil,
        sfSymbolName: String? = nil
    ) -> MirageAction {
        MirageAction(
            id: id,
            displayName: displayName,
            target: .hostKeyInject,
            hostKeyEvent: hostKeyEvent,
            shortcut: shortcut,
            isBuiltIn: false,
            isEnabled: true,
            sfSymbolName: sfSymbolName
        )
    }
}

// MARK: - Built-In Action Identifiers

public extension MirageAction {
    /// Built-in action identifier for switching one desktop space left.
    static let spaceLeftID = "spaceLeft"
    /// Built-in action identifier for switching one desktop space right.
    static let spaceRightID = "spaceRight"
    /// Built-in action identifier for Mission Control.
    static let missionControlID = "missionControl"
    /// Built-in action identifier for App Expose.
    static let appExposeID = "appExpose"
    /// Built-in action identifier for the app switcher.
    static let cmdTabID = "cmdTab"
    /// Built-in action identifier for a host full-screen screenshot.
    static let hostFullScreenScreenshotID = "hostFullScreenScreenshot"
    /// Built-in action identifier for a host selection screenshot.
    static let hostSelectionScreenshotID = "hostSelectionScreenshot"
    /// Built-in action identifier for host screenshot options.
    static let hostScreenshotOptionsID = "hostScreenshotOptions"
    /// Built-in action identifier for local dictation toggle.
    static let dictationToggleID = "dictationToggle"
    /// Built-in action identifier for the local Escape remap.
    static let escapeRemapID = "escapeRemap"
}

// MARK: - Built-In Actions

public extension MirageAction {
    /// Built-in action for switching one desktop space left.
    static let spaceLeft = MirageAction(
        id: spaceLeftID,
        displayName: "Switch Space Left",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x7B, modifiers: .control),
        sfSymbolName: "chevron.left"
    )

    /// Built-in action for switching one desktop space right.
    static let spaceRight = MirageAction(
        id: spaceRightID,
        displayName: "Switch Space Right",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x7C, modifiers: .control),
        sfSymbolName: "chevron.right"
    )

    /// Built-in action for opening Mission Control on the host.
    static let missionControl = MirageAction(
        id: missionControlID,
        displayName: "Mission Control",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x7E, modifiers: .control),
        sfSymbolName: "rectangle.3.group"
    )

    /// Built-in action for opening App Expose on the host.
    static let appExpose = MirageAction(
        id: appExposeID,
        displayName: "App Exposé",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x7D, modifiers: .control),
        sfSymbolName: "squares.below.rectangle"
    )

    /// Built-in action for opening the host app switcher.
    static let cmdTab = MirageAction(
        id: cmdTabID,
        displayName: "App Switcher",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x30, modifiers: .command),
        sfSymbolName: "command"
    )

    /// Built-in action for taking a host full-screen screenshot.
    static let hostFullScreenScreenshot = MirageAction(
        id: hostFullScreenScreenshotID,
        displayName: "Full-Screen Screenshot",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x14, modifiers: [.command, .shift]),
        shortcut: MirageClientShortcutBinding(keyCode: 0x14, modifiers: [.command, .shift, .option]),
        sfSymbolName: "camera.viewfinder"
    )

    /// Built-in action for taking a host selection screenshot.
    static let hostSelectionScreenshot = MirageAction(
        id: hostSelectionScreenshotID,
        displayName: "Selection Screenshot",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x15, modifiers: [.command, .shift]),
        shortcut: MirageClientShortcutBinding(keyCode: 0x15, modifiers: [.command, .shift, .option]),
        sfSymbolName: "rectangle.dashed"
    )

    /// Built-in action for opening host screenshot options.
    static let hostScreenshotOptions = MirageAction(
        id: hostScreenshotOptionsID,
        displayName: "Screenshot Options",
        target: .hostKeyInject,
        hostKeyEvent: MirageKeyEvent(keyCode: 0x17, modifiers: [.command, .shift]),
        shortcut: MirageClientShortcutBinding(keyCode: 0x17, modifiers: [.command, .shift, .option]),
        sfSymbolName: "camera.metering.matrix"
    )

    /// Built-in local action for toggling dictation.
    static let dictationToggle = MirageAction(
        id: dictationToggleID,
        displayName: "Toggle Dictation",
        target: .local,
        shortcut: MirageClientShortcutBinding(keyCode: 0x02, modifiers: [.command, .shift, .option])
    )

    /// Built-in local action for remapping Escape.
    static let escapeRemap = MirageAction(
        id: escapeRemapID,
        displayName: "Escape Remap",
        target: .local,
        shortcut: MirageClientShortcutBinding(keyCode: 0x21, modifiers: .control)
    )

    /// All built-in actions in their default presentation order.
    static let allBuiltIn: [MirageAction] = [
        .spaceLeft, .spaceRight, .missionControl, .appExpose, .cmdTab,
        .hostFullScreenScreenshot, .hostSelectionScreenshot, .hostScreenshotOptions,
        .dictationToggle, .escapeRemap,
    ]
}
