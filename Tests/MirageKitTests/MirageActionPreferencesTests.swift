//
//  MirageActionPreferencesTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/10/26.
//

@testable import MirageKit
import Testing

@Suite("Mirage Action Preferences")
struct MirageActionPreferencesTests {
    @Test("Built-in actions reload with canonical host behavior")
    func builtInActionsReloadWithCanonicalHostBehavior() {
        let storedMissionControl = MirageAction(
            id: MirageAction.missionControlID,
            displayName: "Mission Control Custom",
            target: .local,
            hostKeyEvent: nil,
            shortcut: MirageClientShortcutBinding(keyCode: 0x23, modifiers: .command),
            showInControlBar: false,
            isBuiltIn: true,
            sfSymbolName: "bolt"
        )
        let customAction = MirageAction(
            id: "customAction",
            displayName: "Custom Action",
            target: .hostKeyInject,
            hostKeyEvent: MirageKeyEvent(keyCode: 0x30, modifiers: .option),
            shortcut: nil,
            showInControlBar: true,
            isBuiltIn: false,
            sfSymbolName: "star"
        )

        let normalizedActions = MirageActionPreferences.normalizedLoadedActions([
            storedMissionControl,
            customAction,
        ])

        let missionControlAction = normalizedActions.first { $0.id == MirageAction.missionControlID }

        #expect(missionControlAction?.target == .hostKeyInject)
        #expect(missionControlAction?.hostKeyEvent == MirageAction.missionControl.hostKeyEvent)
        #expect(missionControlAction?.displayName == storedMissionControl.displayName)
        #expect(missionControlAction?.shortcut == storedMissionControl.shortcut)
        #expect(missionControlAction?.showInControlBar == storedMissionControl.showInControlBar)
        #expect(missionControlAction?.sfSymbolName == storedMissionControl.sfSymbolName)
        #expect(normalizedActions.contains(customAction))
    }

    @Test("Built-in host screenshot actions expose request styles")
    func builtInHostScreenshotActionsExposeRequestStyles() throws {
        let preferences = MirageActionPreferences()
        let fullScreen = try #require(preferences.action(withID: MirageAction.hostFullScreenScreenshotID))
        let selection = try #require(preferences.action(withID: MirageAction.hostSelectionScreenshotID))

        #expect(fullScreen.target == .hostScreenshot)
        #expect(fullScreen.hostScreenshotStyle == .fullScreen)
        #expect(fullScreen.showInControlBar)
        #expect(selection.target == .hostScreenshot)
        #expect(selection.hostScreenshotStyle == .selection)
        #expect(selection.showInControlBar)
    }

    @Test("Custom host key bindings are modeled and matched by normalized shortcut")
    func customHostKeyBindingsAreModeledAndMatchedByNormalizedShortcut() throws {
        let action = MirageAction.customHostKeyBinding(
            id: "customHyperEscape",
            displayName: "Hyper Escape",
            hostKeyEvent: MirageKeyEvent(keyCode: 0x35, modifiers: [.control, .option]),
            shortcut: MirageClientShortcutBinding(
                keyCode: 0x35,
                modifiers: [.control, .option, .shift]
            ),
            showInControlBar: true,
            sfSymbolName: "escape"
        )
        let preferences = MirageActionPreferences(actions: [action])
        let keyEvent = MirageKeyEvent(
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

    @Test("Shortcut conflicts normalize Hyper modifier state")
    func shortcutConflictsNormalizeHyperModifierState() throws {
        let existingAction = MirageAction.customHostKeyBinding(
            id: "existingHyperAction",
            displayName: "Existing Hyper Action",
            hostKeyEvent: MirageKeyEvent(keyCode: 0x7E, modifiers: .control),
            shortcut: MirageClientShortcutBinding(
                keyCode: 0x23,
                modifiers: [.control, .option, .shift]
            )
        )
        let preferences = MirageActionPreferences(actions: [existingAction])

        let conflictingAction = try #require(
            preferences.conflictingAction(
                for: MirageClientShortcutBinding(
                    keyCode: 0x23,
                    modifiers: [.control, .option, .shift, .capsLock, .numericPad, .function]
                ),
                excludingActionID: "editedAction"
            )
        )

        #expect(conflictingAction.id == existingAction.id)
    }
}
