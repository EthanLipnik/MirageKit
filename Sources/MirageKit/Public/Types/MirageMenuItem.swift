import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
//
//  MirageWire.MirageMenuItem.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//


// MARK: - Menu Bar


// MARK: - Menu


// MARK: - Menu Item


// MARK: - Keyboard Shortcut


public extension MirageWire.MirageKeyboardShortcut {
    /// Human-readable display string such as `⌘S` or `⇧⌘N`.
    var displayString: String {
        var result = ""

        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }

        result += key.uppercased()
        return result
    }
}
