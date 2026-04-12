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
}
