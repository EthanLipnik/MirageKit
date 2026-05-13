//
//  MiragePencilGestureAction.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

import Foundation

/// Describes the action Mirage should perform for a Pencil hardware gesture.
public enum MiragePencilGestureAction: Codable, Sendable, Hashable {
    /// Do nothing when the gesture fires.
    case none
    /// Send a secondary-click input event.
    case secondaryClick
    /// Toggle client-side dictation capture.
    case toggleDictation
    /// Send a configured keyboard shortcut to the remote Mac.
    case remoteShortcut(MirageClientShortcut)

    /// User-visible action name, including the concrete shortcut for remote shortcut actions.
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

    /// Generic action title used when editing the action type.
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

    /// Configured remote shortcut, or `nil` for non-shortcut actions.
    public var remoteShortcut: MirageClientShortcut? {
        guard case let .remoteShortcut(shortcut) = self else { return nil }
        return shortcut
    }
}
