//
//  MirageActionPreferences.swift
//  MirageInput
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Stores configured input actions.
public struct MirageActionPreferences: Codable, Sendable, Equatable {
    /// Ordered action catalog presented by shortcut settings and runtime matching.
    public var actions: [MirageAction]

    /// Creates preferences with a supplied action catalog, defaulting to built-in actions.
    public init(actions: [MirageAction] = MirageAction.allBuiltIn) {
        self.actions = actions
    }

    /// Find an action whose shortcut matches the given key event.
    public func matchingAction(for keyEvent: MirageKeyEvent) -> MirageAction? {
        actions.first { action in
            guard action.isEnabled else { return false }
            return action.shortcut?.matches(keyEvent) == true
        }
    }

    /// Look up an action by its identifier.
    public func action(withID id: String) -> MirageAction? {
        actions.first { $0.id == id }
    }

    /// Custom remote-host key bindings shown in client settings.
    public var customHostKeyActions: [MirageAction] {
        actions.filter(\.isCustomHostKeyBinding)
    }

    /// Built-in host-key shortcuts shown in client settings.
    public var builtInHostKeyShortcutActions: [MirageAction] {
        actions.filter(\.isBuiltInHostKeyShortcut)
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
    public mutating func removeAction(withID id: String) {
        guard let index = actions.firstIndex(where: { $0.id == id && !$0.isBuiltIn }) else {
            return
        }
        actions.remove(at: index)
    }

    /// Check for shortcut conflicts, excluding the action being edited.
    public func conflictingAction(
        for shortcut: MirageClientShortcutBinding,
        excludingActionID: String
    ) -> MirageAction? {
        let normalizedModifiers = shortcut.modifiers.normalizedForShortcutMatching
        return actions.first { action in
            action.id != excludingActionID &&
                action.isEnabled &&
                action.shortcut?.keyCode == shortcut.keyCode &&
                (action.shortcut?.modifiers.normalizedForShortcutMatching ?? []) == normalizedModifiers
        }
    }
}

public extension MirageActionPreferences {
    /// Merges persisted actions with the current built-in action catalog.
    static func normalizedLoadedActions(_ actions: [MirageAction]) -> [MirageAction] {
        let builtInIDs = Set(MirageAction.allBuiltIn.map(\.id))
        let storedActionsByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })

        let normalizedBuiltIns = MirageAction.allBuiltIn.map { canonicalAction in
            guard let storedAction = storedActionsByID[canonicalAction.id] else {
                return canonicalAction
            }
            var mergedAction = canonicalAction
            mergedAction.displayName = storedAction.displayName
            mergedAction.shortcut = storedAction.shortcut
            mergedAction.isEnabled = storedAction.isEnabled
            mergedAction.sfSymbolName = storedAction.sfSymbolName
            return mergedAction
        }

        let customActions = actions.filter { action in
            !builtInIDs.contains(action.id) || !action.isBuiltIn
        }

        return normalizedBuiltIns + customActions
    }
}
