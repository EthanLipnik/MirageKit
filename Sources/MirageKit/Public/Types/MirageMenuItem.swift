//
//  MirageMenuItem.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import Foundation

// MARK: - Menu Bar

/// Represents the complete menu bar structure of a remote application.
/// Sent from host to client when the streamed app's menus change.
public struct MirageMenuBar: Codable, Sendable, Hashable {
    /// The app's bundle identifier
    public let bundleIdentifier: String

    /// Top-level menus (File, Edit, View, etc.)
    public let menus: [MirageMenu]

    /// Version counter for change detection (increments on each update)
    public let version: UInt64

    public init(bundleIdentifier: String, menus: [MirageMenu], version: UInt64) {
        self.bundleIdentifier = bundleIdentifier
        self.menus = menus
        self.version = version
    }
}

// MARK: - Menu

/// Represents a top-level menu (e.g., File, Edit, View).
public struct MirageMenu: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID

    /// Menu title (e.g., "File", "Edit")
    public let title: String

    /// Items within this menu
    public let items: [MirageMenuItem]

    /// Index of this menu in the menu bar (for action paths)
    public let menuIndex: Int

    public init(id: UUID = UUID(), title: String, items: [MirageMenuItem], menuIndex: Int) {
        self.id = id
        self.title = title
        self.items = items
        self.menuIndex = menuIndex
    }
}

// MARK: - Menu Item

/// Represents a single menu item in the remote app's menu bar.
public struct MirageMenuItem: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID

    /// Display title of the menu item
    public let title: String

    /// Whether this item is currently enabled
    public let isEnabled: Bool

    /// Whether this is a separator line
    public let isSeparator: Bool

    /// Keyboard shortcut, if any
    public let keyboardShortcut: MirageKeyboardShortcut?

    /// Submenu items, if this item has a submenu
    public let submenu: [MirageMenuItem]?

    /// Path from menu bar to this item for triggering actions.
    /// e.g., [1, 0] = second menu, first item
    /// e.g., [0, 2, 1] = first menu, third item, second submenu item
    public let actionPath: [Int]

    /// Whether this item has a checkmark
    public let isChecked: Bool

    /// Whether this item is in mixed state (dash mark)
    public let isMixed: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        isEnabled: Bool = true,
        isSeparator: Bool = false,
        keyboardShortcut: MirageKeyboardShortcut? = nil,
        submenu: [MirageMenuItem]? = nil,
        actionPath: [Int],
        isChecked: Bool = false,
        isMixed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.isSeparator = isSeparator
        self.keyboardShortcut = keyboardShortcut
        self.submenu = submenu
        self.actionPath = actionPath
        self.isChecked = isChecked
        self.isMixed = isMixed
    }

    /// Creates a separator item
    public static func separator(actionPath: [Int]) -> MirageMenuItem {
        MirageMenuItem(
            title: "",
            isEnabled: false,
            isSeparator: true,
            actionPath: actionPath
        )
    }
}

// MARK: - Keyboard Shortcut

/// Represents a keyboard shortcut for a menu item.
public struct MirageKeyboardShortcut: Codable, Sendable, Hashable {
    /// The key character (e.g., "S", "N", "Z")
    /// For function keys, uses "F1", "F2", etc.
    public let key: String

    /// Modifier flags (command, shift, option, control)
    public let modifiers: MirageModifierFlags

    public init(key: String, modifiers: MirageModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Human-readable display string (e.g., "⌘S", "⇧⌘N")
    public var displayString: String {
        var result = ""

        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }

        result += key.uppercased()
        return result
    }
}
