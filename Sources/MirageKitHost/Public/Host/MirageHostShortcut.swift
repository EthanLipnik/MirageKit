//
//  MirageHostShortcut.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Host shortcut model for local emergency recovery actions.
//

import Foundation
import MirageKit

public struct MirageHostShortcut: Codable, Sendable, Hashable {
    public let keyCode: UInt16
    public let modifiers: MirageModifierFlags

    public init(keyCode: UInt16, modifiers: MirageModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let defaultLightsOutRecovery = MirageHostShortcut(
        keyCode: 0x35, // Escape
        modifiers: [.control, .option, .command]
    )

    public func matches(keyCode: UInt16, modifiers: MirageModifierFlags) -> Bool {
        keyCode == self.keyCode &&
            Self.normalizedShortcutModifiers(modifiers) == Self.normalizedShortcutModifiers(self.modifiers)
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

    public static func normalizedShortcutModifiers(_ flags: MirageModifierFlags) -> MirageModifierFlags {
        var normalized: MirageModifierFlags = []
        if flags.contains(.command) { normalized.insert(.command) }
        if flags.contains(.shift) { normalized.insert(.shift) }
        if flags.contains(.option) { normalized.insert(.option) }
        if flags.contains(.control) { normalized.insert(.control) }
        return normalized
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
