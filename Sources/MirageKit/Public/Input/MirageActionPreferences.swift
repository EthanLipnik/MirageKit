//
//  MirageActionPreferences.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/6/26.
//

import Foundation

/// Stores all configured actions (built-in + custom) and persists them to UserDefaults.
public struct MirageActionPreferences: Codable, Sendable, Equatable {
    public var actions: [MirageAction]

    public init(actions: [MirageAction] = MirageAction.allBuiltIn) {
        self.actions = actions
    }

    /// Find an action whose shortcut matches the given key event.
    public func matchingAction(for keyEvent: MirageKeyEvent) -> MirageAction? {
        actions.first { action in
            action.shortcut?.matches(keyEvent) == true
        }
    }

    /// All actions that should appear in the stream control bar.
    public var controlBarActions: [MirageAction] {
        actions.filter(\.showInControlBar)
    }

    /// Look up an action by its identifier.
    public func action(withID id: String) -> MirageAction? {
        actions.first { $0.id == id }
    }

    /// Update an existing action in place.
    public mutating func updateAction(_ action: MirageAction) {
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        }
    }

    /// Add a custom action.
    public mutating func addAction(_ action: MirageAction) {
        actions.append(action)
    }

    /// Remove a custom action. Built-in actions cannot be removed.
    @discardableResult
    public mutating func removeAction(withID id: String) -> Bool {
        guard let index = actions.firstIndex(where: { $0.id == id && !$0.isBuiltIn }) else {
            return false
        }
        actions.remove(at: index)
        return true
    }

    /// Check for shortcut conflicts, excluding the action being edited.
    public func conflictingAction(
        for shortcut: MirageClientShortcutBinding,
        excludingActionID: String
    ) -> MirageAction? {
        actions.first { action in
            action.id != excludingActionID &&
                action.shortcut?.keyCode == shortcut.keyCode &&
                MirageClientShortcutBinding.normalizedModifiers(action.shortcut?.modifiers ?? []) ==
                MirageClientShortcutBinding.normalizedModifiers(shortcut.modifiers)
        }
    }
}

// MARK: - UserDefaults Persistence

public extension MirageActionPreferences {
    private static let userDefaultsKey = "MirageActionPreferences"

    static func load() -> MirageActionPreferences {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let prefs = try? JSONDecoder().decode(MirageActionPreferences.self, from: data) else {
            return MirageActionPreferences()
        }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

}
