//
//  MiragePencilGestureAction.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

import Foundation

/// Describes the action Mirage should perform for a Pencil hardware gesture.
public enum MiragePencilGestureAction: Codable, Sendable, Hashable {
    case none
    case secondaryClick
    case toggleDictation
    case remoteShortcut(MirageClientShortcut)

    public var displayName: String {
        switch self {
        case .none:
            "No Action"
        case .secondaryClick:
            "Secondary Click"
        case .toggleDictation:
            "Toggle Dictation"
        case let .remoteShortcut(shortcut):
            shortcut.displayString
        }
    }

    public var actionTitle: String {
        switch self {
        case .none:
            "No Action"
        case .secondaryClick:
            "Secondary Click"
        case .toggleDictation:
            "Toggle Dictation"
        case .remoteShortcut:
            "Remote Mac Shortcut"
        }
    }

    public var remoteShortcut: MirageClientShortcut? {
        guard case let .remoteShortcut(shortcut) = self else { return nil }
        return shortcut
    }
}
