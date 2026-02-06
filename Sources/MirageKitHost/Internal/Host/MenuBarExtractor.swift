//
//  MenuBarExtractor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import MirageKit
#if os(macOS)
import ApplicationServices
import Foundation

/// Extracts menu bar structure from running applications using Accessibility APIs.
///
/// This actor provides thread-safe access to menu bar extraction and action execution.
/// Menu structures are extracted by traversing the Accessibility element tree starting
/// from the application's menu bar attribute.
actor MenuBarExtractor {
    // MARK: - Menu Bar Extraction

    /// Extracts the complete menu bar structure from an application.
    ///
    /// - Parameters:
    ///   - pid: Process ID of the target application
    ///   - bundleIdentifier: Bundle identifier for identification
    /// - Returns: The menu bar structure, or nil if extraction fails
    func extractMenuBar(for pid: pid_t, bundleIdentifier: String) -> MirageMenuBar? {
        let appElement = AXUIElementCreateApplication(pid)

        // Get the menu bar element
        var menuBarRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXMenuBarAttribute as CFString,
            &menuBarRef
        )

        guard result == .success, let menuBar = menuBarRef else {
            MirageLogger.log(.menuBar, "Failed to get menu bar for pid \(pid): AXError \(result.rawValue)")
            return nil
        }

        // Get the top-level menu bar items (File, Edit, View, etc.)
        var childrenRef: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(
            menuBar as! AXUIElement,
            kAXChildrenAttribute as CFString,
            &childrenRef
        )

        guard childrenResult == .success, let children = childrenRef as? [AXUIElement] else {
            MirageLogger.log(.menuBar, "Failed to get menu bar children: AXError \(childrenResult.rawValue)")
            return nil
        }

        // Skip the first child if it's the Apple menu (we don't want to expose that)
        let menuStartIndex = shouldSkipAppleMenu(children) ? 1 : 0

        var menus: [MirageMenu] = []
        for (index, menuBarItem) in children.enumerated() where index >= menuStartIndex {
            if let menu = extractMenu(from: menuBarItem, menuIndex: index) { menus.append(menu) }
        }

        return MirageMenuBar(
            bundleIdentifier: bundleIdentifier,
            menus: menus,
            version: UInt64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Checks if the first menu bar item is the Apple menu (which we skip).
    private func shouldSkipAppleMenu(_ children: [AXUIElement]) -> Bool {
        guard let first = children.first else { return false }

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(first, kAXTitleAttribute as CFString, &titleRef)

        if let title = titleRef as? String {
            // Apple menu often has an empty title or the Apple symbol
            return title.isEmpty || title == "" || title == "\u{F8FF}"
        }

        return false
    }

    // MARK: - Menu Extraction

    /// Extracts a single top-level menu from a menu bar item.
    private func extractMenu(from menuBarItem: AXUIElement, menuIndex: Int) -> MirageMenu? {
        // Get the menu title
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(menuBarItem, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""

        // Skip empty or system menus
        if title.isEmpty { return nil }

        // Get the submenu (the actual menu with items)
        var submenuRef: CFTypeRef?
        let submenuResult = AXUIElementCopyAttributeValue(
            menuBarItem,
            kAXChildrenAttribute as CFString,
            &submenuRef
        )

        guard submenuResult == .success, let submenus = submenuRef as? [AXUIElement], !submenus.isEmpty else {
            // No submenu - this shouldn't happen for normal menus
            return MirageMenu(title: title, items: [], menuIndex: menuIndex)
        }

        // The first child of a menu bar item is the actual menu
        let menuElement = submenus[0]

        // Get menu items
        var menuItemsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(menuElement, kAXChildrenAttribute as CFString, &menuItemsRef)

        guard let menuItemElements = menuItemsRef as? [AXUIElement] else { return MirageMenu(title: title, items: [], menuIndex: menuIndex) }

        var items: [MirageMenuItem] = []
        for (itemIndex, itemElement) in menuItemElements.enumerated() {
            let actionPath = [menuIndex, itemIndex]
            if let item = extractMenuItem(from: itemElement, actionPath: actionPath) { items.append(item) }
        }

        return MirageMenu(title: title, items: items, menuIndex: menuIndex)
    }

    // MARK: - Menu Item Extraction

    /// Extracts a single menu item, including any submenu items recursively.
    private func extractMenuItem(from element: AXUIElement, actionPath: [Int]) -> MirageMenuItem? {
        // Check if this is a separator
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        if role == "AXMenuItemSeparator" || role == kAXMenuItemRole as String {
            // Check for separator by lack of title
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String

            if title == nil || title?.isEmpty == true {
                // Could be a separator - check subrole
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
                let subrole = subroleRef as? String

                if subrole == "AXSeparatorMenuItemSubrole" || title == nil { return .separator(actionPath: actionPath) }
            }
        }

        // Get title
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""

        // Empty titles that aren't separators - skip them
        if title.isEmpty { return nil }

        // Get enabled state
        var enabledRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef)
        let isEnabled = (enabledRef as? Bool) ?? true

        // Get keyboard shortcut
        let keyboardShortcut = extractKeyboardShortcut(from: element)

        // Get check/mixed state
        var markRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXMenuItemMarkCharAttribute as CFString, &markRef)
        let markChar = markRef as? String

        let isChecked = markChar == "✓" || markChar == "\u{2713}"
        let isMixed = markChar == "-" || markChar == "\u{2212}" || markChar == "–"

        // Check for submenu
        var submenuItems: [MirageMenuItem]?
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)

        if let children = childrenRef as? [AXUIElement], !children.isEmpty {
            // This item has a submenu
            // The first child should be the submenu element
            if let submenuElement = children.first {
                var submenuChildrenRef: CFTypeRef?
                AXUIElementCopyAttributeValue(submenuElement, kAXChildrenAttribute as CFString, &submenuChildrenRef)

                if let submenuChildElements = submenuChildrenRef as? [AXUIElement] {
                    submenuItems = []
                    for (subIndex, subElement) in submenuChildElements.enumerated() {
                        let subPath = actionPath + [subIndex]
                        if let subItem = extractMenuItem(from: subElement, actionPath: subPath) { submenuItems?.append(subItem) }
                    }
                }
            }
        }

        return MirageMenuItem(
            title: title,
            isEnabled: isEnabled,
            isSeparator: false,
            keyboardShortcut: keyboardShortcut,
            submenu: submenuItems,
            actionPath: actionPath,
            isChecked: isChecked,
            isMixed: isMixed
        )
    }

    /// Extracts keyboard shortcut from a menu item element.
    private func extractKeyboardShortcut(from element: AXUIElement) -> MirageKeyboardShortcut? {
        // Get the command key character
        var cmdCharRef: CFTypeRef?
        let charResult = AXUIElementCopyAttributeValue(
            element,
            kAXMenuItemCmdCharAttribute as CFString,
            &cmdCharRef
        )

        // If no command character, check for virtual key
        var keyChar: String?
        if charResult == .success, let char = cmdCharRef as? String, !char.isEmpty { keyChar = char } else {
            // Try virtual key for function keys, etc.
            var virtualKeyRef: CFTypeRef?
            let vkResult = AXUIElementCopyAttributeValue(
                element,
                kAXMenuItemCmdVirtualKeyAttribute as CFString,
                &virtualKeyRef
            )

            if vkResult == .success, let vk = virtualKeyRef as? Int { keyChar = virtualKeyCodeToString(UInt16(vk)) }
        }

        guard let key = keyChar else { return nil }

        // Get modifiers
        var modifiersRef: CFTypeRef?
        AXUIElementCopyAttributeValue(
            element,
            kAXMenuItemCmdModifiersAttribute as CFString,
            &modifiersRef
        )

        let axModifiers = (modifiersRef as? UInt) ?? 0

        // Convert AX modifiers to MirageModifierFlags
        // AX modifier flags:
        // 1 << 0 = Shift
        // 1 << 1 = Option
        // 1 << 2 = Control
        // 1 << 3 = (unused, was Caps Lock in some docs)
        // Command is implicit in menu shortcuts
        var modifiers = MirageModifierFlags.command // Always has command for menu shortcuts

        if axModifiers & (1 << 0) != 0 { modifiers.insert(.shift) }
        if axModifiers & (1 << 1) != 0 { modifiers.insert(.option) }
        if axModifiers & (1 << 2) != 0 { modifiers.insert(.control) }

        return MirageKeyboardShortcut(key: key, modifiers: modifiers)
    }

    /// Converts a virtual key code to a display string.
    private func virtualKeyCodeToString(_ keyCode: UInt16) -> String? {
        // Function keys
        switch keyCode {
        case 0x7A: "F1"
        case 0x78: "F2"
        case 0x63: "F3"
        case 0x76: "F4"
        case 0x60: "F5"
        case 0x61: "F6"
        case 0x62: "F7"
        case 0x64: "F8"
        case 0x65: "F9"
        case 0x6D: "F10"
        case 0x67: "F11"
        case 0x6F: "F12"
        case 0x69: "F13"
        case 0x6B: "F14"
        case 0x71: "F15"
        case 0x6A: "F16"
        case 0x40: "F17"
        case 0x4F: "F18"
        case 0x50: "F19"
        case 0x5A: "F20"
        // Special keys
        case 0x24: "↩" // Return
        case 0x30: "⇥" // Tab
        case 0x31: "Space"
        case 0x33: "⌫" // Delete
        case 0x35: "⎋" // Escape
        case 0x7B: "←" // Left Arrow
        case 0x7C: "→" // Right Arrow
        case 0x7D: "↓" // Down Arrow
        case 0x7E: "↑" // Up Arrow
        case 0x73: "↖" // Home
        case 0x77: "↘" // End
        case 0x74: "⇞" // Page Up
        case 0x79: "⇟" // Page Down
        case 0x75: "⌦" // Forward Delete
        default: nil
        }
    }

    // MARK: - Action Execution

    /// Performs a menu action by navigating to the item and pressing it.
    ///
    /// - Parameters:
    ///   - pid: Process ID of the target application
    ///   - actionPath: Path to the menu item [menuIndex, itemIndex, submenuIndex, ...]
    /// - Returns: True if the action was performed successfully
    func performMenuAction(pid: pid_t, actionPath: [Int]) -> Bool {
        guard actionPath.count >= 2 else {
            MirageLogger.log(.menuBar, "Action path too short: \(actionPath)")
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Get the menu bar
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef as! AXUIElement? else {
            MirageLogger.log(.menuBar, "Failed to get menu bar for action")
            return false
        }

        // Get menu bar items
        var menuBarChildrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &menuBarChildrenRef) == .success,
              let menuBarItems = menuBarChildrenRef as? [AXUIElement],
              actionPath[0] < menuBarItems.count else {
            MirageLogger.log(.menuBar, "Invalid menu index: \(actionPath[0])")
            return false
        }

        // Navigate through the menu hierarchy
        var currentItems: [AXUIElement] = menuBarItems
        var targetElement: AXUIElement?

        for (depth, index) in actionPath.enumerated() {
            guard index < currentItems.count else {
                MirageLogger.log(.menuBar, "Invalid index \(index) at depth \(depth)")
                return false
            }

            let element = currentItems[index]

            if depth == actionPath.count - 1 {
                // This is the target item
                targetElement = element
            } else {
                // Need to navigate into this element's children (submenu)
                var childrenRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) ==
                    .success,
                    let children = childrenRef as? [AXUIElement],
                    !children.isEmpty else {
                    MirageLogger.log(.menuBar, "Failed to get children at depth \(depth)")
                    return false
                }

                // The first child is the submenu element, get its children
                var submenuItemsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(children[0], kAXChildrenAttribute as CFString, &submenuItemsRef) ==
                    .success,
                    let submenuItems = submenuItemsRef as? [AXUIElement] else {
                    MirageLogger.log(.menuBar, "Failed to get submenu items at depth \(depth)")
                    return false
                }

                currentItems = submenuItems
            }
        }

        guard let target = targetElement else {
            MirageLogger.log(.menuBar, "Failed to find target element")
            return false
        }

        // Perform the press action
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)

        if result != .success {
            MirageLogger.log(.menuBar, "Failed to perform press action: AXError \(result.rawValue)")
            return false
        }

        return true
    }
}

#endif
