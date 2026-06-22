//
//  MirageActionPreferencesTests.swift
//  MirageInput
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageInput
import Testing

@Suite("Mirage Action Preferences")
struct MirageActionPreferencesTests {
    @Test("Built-in actions reload with canonical host behavior")
    func builtInActionsReloadWithCanonicalHostBehavior() {
        let storedMissionControl = MirageInput.MirageAction(
            id: MirageInput.MirageAction.missionControlID,
            displayName: "Mission Control Custom",
            target: .local,
            hostKeyEvent: nil,
            shortcut: MirageInput.MirageClientShortcutBinding(keyCode: 0x23, modifiers: .command),
            isBuiltIn: true,
            isEnabled: false,
            sfSymbolName: "bolt"
        )
        let customAction = MirageInput.MirageAction(
            id: "customAction",
            displayName: "Custom Action",
            target: .hostKeyInject,
            hostKeyEvent: MirageInput.MirageKeyEvent(keyCode: 0x30, modifiers: .option),
            shortcut: nil,
            isBuiltIn: false,
            sfSymbolName: "star"
        )

        let normalizedActions = MirageInput.MirageActionPreferences.normalizedLoadedActions([
            storedMissionControl,
            customAction,
        ])

        let missionControlAction = normalizedActions.first { $0.id == MirageInput.MirageAction.missionControlID }

        #expect(missionControlAction?.target == .hostKeyInject)
        #expect(missionControlAction?.hostKeyEvent == MirageInput.MirageAction.missionControl.hostKeyEvent)
        #expect(missionControlAction?.displayName == storedMissionControl.displayName)
        #expect(missionControlAction?.shortcut == storedMissionControl.shortcut)
        #expect(missionControlAction?.isEnabled == storedMissionControl.isEnabled)
        #expect(missionControlAction?.sfSymbolName == storedMissionControl.sfSymbolName)
        #expect(normalizedActions.contains(customAction))
    }

    @Test("Custom host key bindings are modeled and matched by normalized shortcut")
    func customHostKeyBindingsAreModeledAndMatchedByNormalizedShortcut() throws {
        let action = MirageInput.MirageAction.customHostKeyBinding(
            id: "customHyperEscape",
            displayName: "Hyper Escape",
            hostKeyEvent: MirageInput.MirageKeyEvent(keyCode: 0x35, modifiers: [.control, .option]),
            shortcut: MirageInput.MirageClientShortcutBinding(
                keyCode: 0x35,
                modifiers: [.control, .option, .shift]
            ),
            sfSymbolName: "escape"
        )
        let preferences = MirageInput.MirageActionPreferences(actions: [action])
        let keyEvent = MirageInput.MirageKeyEvent(
            keyCode: 0x35,
            modifiers: [.control, .option, .shift, .capsLock, .numericPad, .function]
        )

        let matchedAction = try #require(preferences.matchingAction(for: keyEvent))

        #expect(action.target == .hostKeyInject)
        #expect(action.hostKeyEvent?.keyCode == 0x35)
        #expect(action.hostKeyEvent?.modifiers == [.control, .option])
        #expect(!action.isBuiltIn)
        #expect(matchedAction.id == action.id)
    }

    @Test("Disabled actions do not match shortcuts or report shortcut conflicts")
    func disabledActionsDoNotMatchShortcutsOrReportShortcutConflicts() {
        var action = MirageInput.MirageAction.customHostKeyBinding(
            id: "disabledAction",
            displayName: "Disabled Action",
            hostKeyEvent: MirageInput.MirageKeyEvent(keyCode: 0x35, modifiers: [.control]),
            shortcut: MirageInput.MirageClientShortcutBinding(
                keyCode: 0x35,
                modifiers: [.control, .option, .shift]
            )
        )
        action.isEnabled = false
        let preferences = MirageInput.MirageActionPreferences(actions: [action])
        let shortcut = MirageInput.MirageClientShortcutBinding(
            keyCode: 0x35,
            modifiers: [.control, .option, .shift]
        )
        let keyEvent = MirageInput.MirageKeyEvent(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers
        )

        #expect(preferences.matchingAction(for: keyEvent) == nil)
        #expect(preferences.conflictingAction(for: shortcut, excludingActionID: "editedAction") == nil)
    }

    @Test("Shortcut conflicts normalize Hyper modifier state")
    func shortcutConflictsNormalizeHyperModifierState() throws {
        let existingAction = MirageInput.MirageAction.customHostKeyBinding(
            id: "existingHyperAction",
            displayName: "Existing Hyper Action",
            hostKeyEvent: MirageInput.MirageKeyEvent(keyCode: 0x7E, modifiers: .control),
            shortcut: MirageInput.MirageClientShortcutBinding(
                keyCode: 0x23,
                modifiers: [.control, .option, .shift]
            )
        )
        let preferences = MirageInput.MirageActionPreferences(actions: [existingAction])

        let conflictingAction = try #require(
            preferences.conflictingAction(
                for: MirageInput.MirageClientShortcutBinding(
                    keyCode: 0x23,
                    modifiers: [.control, .option, .shift, .capsLock, .numericPad, .function]
                ),
                excludingActionID: "editedAction"
            )
        )

        #expect(conflictingAction.id == existingAction.id)
    }
}
