//
//  MirageInterceptedShortcutResponderTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

#if os(iOS) || os(visionOS)
@testable import MirageKitClient
import MirageKit
import Testing
import UIKit

@MainActor
@Suite("Intercepted shortcut responder routing")
struct MirageInterceptedShortcutResponderTests {
    @Test("Cmd+B forwards once when both keyCommand and edit action paths fire")
    func cmdBForwardsOnceAcrossResponderEntryPoints() {
        let view = InputCapturingView(frame: .zero)
        var keyDownEvents: [MirageKeyEvent] = []
        var keyUpEvents: [MirageKeyEvent] = []
        var flagsChangedCount = 0

        view.onInputEvent = { event in
            switch event {
            case .keyDown(let keyEvent):
                keyDownEvents.append(keyEvent)
            case .keyUp(let keyEvent):
                keyUpEvents.append(keyEvent)
            case .flagsChanged(_):
                flagsChangedCount += 1
            default:
                break
            }
        }

        keyDownEvents.removeAll()
        keyUpEvents.removeAll()
        flagsChangedCount = 0

        let command = UIKeyCommand(
            action: Selector(("handlePassthroughShortcut:")),
            input: "b",
            modifierFlags: .command
        )

        view.handlePassthroughShortcut(command)
        view.toggleBoldface(nil)

        #expect(keyDownEvents.count == 1)
        #expect(keyUpEvents.count == 1)
        #expect(flagsChangedCount == 0)

        #expect(keyDownEvents.first?.keyCode == 0x0B)
        #expect(keyDownEvents.first?.characters == "b")
        #expect(keyDownEvents.first?.modifiers == [.command])
        #expect(keyUpEvents.first?.keyCode == 0x0B)
        #expect(keyUpEvents.first?.characters == "b")
        #expect(keyUpEvents.first?.modifiers == [.command])
    }

    @Test("Client shortcut overrides conflicting Cmd+B responder routing")
    func clientShortcutOverridesConflictingCmdBResponderRouting() throws {
        let view = InputCapturingView(frame: .zero)
        let shortcut = MirageClientShortcut(keyCode: 0x0B, modifiers: [.command])
        var triggeredShortcuts: [MirageClientShortcut] = []
        var keyDownEvents: [MirageKeyEvent] = []
        var keyUpEvents: [MirageKeyEvent] = []

        view.clientShortcuts = [shortcut]
        view.onClientShortcut = { triggeredShortcuts.append($0) }
        view.onInputEvent = { event in
            switch event {
            case .keyDown(let keyEvent):
                keyDownEvents.append(keyEvent)
            case .keyUp(let keyEvent):
                keyUpEvents.append(keyEvent)
            default:
                break
            }
        }

        let matchingCommands = try #require(view.keyCommands?.filter { command in
            command.input == "b" && command.modifierFlags == .command
        })
        #expect(matchingCommands.count == 1)
        #expect(matchingCommands.first?.action == Selector(("handleClientShortcutCommand:")))

        let command = UIKeyCommand(
            action: Selector(("handleClientShortcutCommand:")),
            input: "b",
            modifierFlags: .command
        )

        view.handleClientShortcutCommand(command)
        view.toggleBoldface(nil)

        #expect(triggeredShortcuts == [shortcut])
        #expect(keyDownEvents.isEmpty)
        #expect(keyUpEvents.isEmpty)
    }
}
#endif
