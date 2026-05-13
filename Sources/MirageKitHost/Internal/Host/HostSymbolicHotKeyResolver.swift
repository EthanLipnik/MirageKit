//
//  HostSymbolicHotKeyResolver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/11/26.
//

import Foundation
import MirageKit

#if os(macOS)
/// Result of resolving a macOS symbolic hot key for a host system action.
enum HostSymbolicHotKeyResolution: Equatable {
    /// The action has an enabled shortcut that can be forwarded to the host.
    case shortcut(MirageKeyEvent)

    /// The symbolic hot key exists but is disabled in System Settings.
    case disabled

    /// The symbolic hot key cannot be read or does not contain usable key parameters.
    case unavailable
}

/// Reads macOS symbolic hot-key preferences and maps supported system actions to Mirage key events.
enum HostSymbolicHotKeyResolver {
    private static let symbolicHotKeyPlistRelativePath = "Library/Preferences/com.apple.symbolichotkeys.plist"
    private static let shiftModifierMask: UInt = 1 << 17
    private static let controlModifierMask: UInt = 1 << 18
    private static let optionModifierMask: UInt = 1 << 19
    private static let commandModifierMask: UInt = 1 << 20
    private static let functionModifierMask: UInt = 1 << 23

    static func resolve(
        _ action: MirageHostSystemAction,
        fileManager: FileManager = .default
    ) -> HostSymbolicHotKeyResolution {
        let preferencesURL = fileManager.homeDirectoryForCurrentUser.appending(
            path: symbolicHotKeyPlistRelativePath
        )
        guard let data = try? Data(contentsOf: preferencesURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ),
              let rootDictionary = propertyList as? [AnyHashable: Any] else {
            return .unavailable
        }

        return resolve(action, propertyList: rootDictionary)
    }

    static func resolve(
        _ action: MirageHostSystemAction,
        propertyList: [AnyHashable: Any]
    ) -> HostSymbolicHotKeyResolution {
        guard let hotKeysDictionary = propertyList["AppleSymbolicHotKeys"] as? [AnyHashable: Any] else {
            return .unavailable
        }
        guard let hotKeyEntry = hotKeysDictionary[String(action.symbolicHotKeyID)] as? [AnyHashable: Any] else {
            return .unavailable
        }
        return resolveHotKeyEntry(hotKeyEntry)
    }

    private static func resolveHotKeyEntry(
        _ hotKeyEntry: [AnyHashable: Any]
    ) -> HostSymbolicHotKeyResolution {
        if let enabled = hotKeyEntry["enabled"] as? Bool, !enabled {
            return .disabled
        }

        guard let valueDictionary = hotKeyEntry["value"] as? [AnyHashable: Any],
              let parameters = valueDictionary["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCodeParameter = parameters.dropFirst().first,
              let modifierFlagsParameter = parameters.dropFirst(2).first,
              let keyCode = integerValue(keyCodeParameter),
              let modifierFlagsRaw = unsignedIntegerValue(modifierFlagsParameter),
              let resolvedKeyCode = UInt16(exactly: keyCode) else {
            return .unavailable
        }

        return .shortcut(MirageKeyEvent(
            keyCode: resolvedKeyCode,
            modifiers: modifiers(fromSymbolicHotKeyFlags: modifierFlagsRaw)
        ))
    }

    private static func modifiers(fromSymbolicHotKeyFlags rawValue: UInt) -> MirageModifierFlags {
        var modifiers: MirageModifierFlags = []
        if rawValue & shiftModifierMask != 0 { modifiers.insert(.shift) }
        if rawValue & controlModifierMask != 0 { modifiers.insert(.control) }
        if rawValue & optionModifierMask != 0 { modifiers.insert(.option) }
        if rawValue & commandModifierMask != 0 { modifiers.insert(.command) }
        if rawValue & functionModifierMask != 0 { modifiers.insert(.function) }
        return modifiers
    }

    private static func integerValue(_ value: Any) -> Int? {
        switch value {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        default:
            nil
        }
    }

    private static func unsignedIntegerValue(_ value: Any) -> UInt? {
        switch value {
        case let value as UInt:
            value
        case let value as NSNumber:
            UInt(exactly: value.int64Value)
        default:
            nil
        }
    }
}

private extension MirageHostSystemAction {
    /// AppleSymbolicHotKeys preference identifier for this host system action.
    var symbolicHotKeyID: Int {
        switch self {
        case .spaceLeft:
            79
        case .spaceRight:
            81
        case .missionControl:
            32
        case .appExpose:
            33
        }
    }
}
#endif
