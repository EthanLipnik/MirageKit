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
}
#endif
