//
//  MirageMenuModels.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageInput

// MARK: - Menu Bar

/// Represents the complete menu bar structure of a remote application.
public struct MirageMenuBar: Codable, Sendable, Hashable {
    /// Bundle identifier for the app that owns this menu bar.
    public let bundleIdentifier: String

    /// Top-level menus such as File, Edit, and View.
    public let menus: [MirageMenu]

    /// Monotonic version counter used for change detection.
    public let version: UInt64

    /// Creates a remote menu-bar snapshot for one host application.
    public init(bundleIdentifier: String, menus: [MirageMenu], version: UInt64) {
        self.bundleIdentifier = bundleIdentifier
        self.menus = menus
        self.version = version
    }
}

// MARK: - Menu

/// Represents a top-level menu.
public struct MirageMenu: Codable, Sendable, Identifiable, Hashable {
    /// Stable menu identity for client-side diffing.
    public let id: UUID

    /// Menu title.
    public let title: String

    /// Items within this menu.
    public let items: [MirageMenuItem]

    /// Index of this menu in the menu bar for action paths.
    public let menuIndex: Int

    /// Creates a top-level menu snapshot.
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
    /// Stable menu-item identity for client-side diffing.
    public let id: UUID

    /// Display title of the menu item.
    public let title: String

    /// Whether this item is currently enabled.
    public let isEnabled: Bool

    /// Whether this is a separator line.
    public let isSeparator: Bool

    /// Keyboard shortcut, if any.
    public let keyboardShortcut: MirageKeyboardShortcut?

    /// Submenu items, if this item has a submenu.
    public let submenu: [MirageMenuItem]?

    /// Path from menu bar to this item for triggering actions.
    public let actionPath: [Int]

    /// Whether this item has a checkmark.
    public let isChecked: Bool

    /// Whether this item is in mixed state.
    public let isMixed: Bool

    /// Creates a remote menu-item snapshot.
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

    /// Creates a separator item.
    /// - Parameter actionPath: Path from the menu bar to the separator's position.
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
    /// Key character, or function-key label such as `F1`.
    public let key: String

    /// Modifier flags such as Command, Shift, Option, and Control.
    public let modifiers: MirageInput.MirageModifierFlags

    /// Creates a keyboard shortcut displayed beside a remote menu item.
    public init(key: String, modifiers: MirageInput.MirageModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }
}
