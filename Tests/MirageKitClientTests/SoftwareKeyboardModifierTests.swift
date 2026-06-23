//
//  SoftwareKeyboardModifierTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/23/26.
//

#if os(iOS) || os(visionOS)
import MirageKit
@testable import MirageKitClient
import Testing
import UIKit

@MainActor
@Suite("Software keyboard modifiers")
struct SoftwareKeyboardModifierTests {
    @Test("Accessory keeps a usable minimum height")
    func accessoryKeepsUsableMinimumHeight() {
        let accessoryView = SoftwareKeyboardAccessoryView()

        #expect(accessoryView.intrinsicContentSize.height >= 52)
        #expect(accessoryView.sizeThatFits(CGSize(width: 300, height: 1)).height >= 52)
    }

    @Test("Single tap modifier clears after one software key")
    func singleTapModifierClearsAfterOneSoftwareKey() {
        let view = InputCapturingView(frame: .zero)
        var events: [MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }

        view.handleSoftwareModifierTap(.commandKey, tapCount: 1)
        view.handleSoftwareKeyboardInsertText("a")

        let keyDowns = keyDownEvents(from: events)
        #expect(keyDowns.count == 1)
        #expect(keyDowns[0].modifiers.contains(.command))
        #expect(view.softwareMomentaryModifiers.isEmpty)
        #expect(view.softwareLockedModifiers.isEmpty)
        #expect(flagEvents(from: events).last?.isEmpty == true)
    }

    @Test("Double tap modifier stays locked until tapped again")
    func doubleTapModifierStaysLockedUntilTappedAgain() {
        let view = InputCapturingView(frame: .zero)
        var events: [MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }

        view.handleSoftwareModifierTap(.commandKey, tapCount: 1)
        view.handleSoftwareModifierTap(.commandKey, tapCount: 2)
        view.handleSoftwareKeyboardInsertText("a")
        view.handleSoftwareKeyboardInsertText("b")

        let keyDowns = keyDownEvents(from: events)
        #expect(keyDowns.count == 2)
        #expect(keyDowns.allSatisfy { $0.modifiers.contains(.command) })
        #expect(view.softwareMomentaryModifiers.isEmpty)
        #expect(view.softwareLockedModifiers.contains(.command))

        view.handleSoftwareModifierTap(.commandKey, tapCount: 1)

        #expect(view.softwareLockedModifiers.isEmpty)
        #expect(flagEvents(from: events).last?.isEmpty == true)
    }

    @Test("Holding modifier locks it until tapped again")
    func holdingModifierLocksItUntilTappedAgain() {
        let view = InputCapturingView(frame: .zero)
        var events: [MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }

        view.handleSoftwareModifierHold(.optionKey)
        view.handleSoftwareKeyboardDeleteBackward()

        let keyDowns = keyDownEvents(from: events)
        #expect(keyDowns.count == 1)
        #expect(keyDowns[0].keyCode == 0x33)
        #expect(keyDowns[0].modifiers.contains(.option))
        #expect(view.softwareLockedModifiers.contains(.option))

        view.handleSoftwareModifierTap(.optionKey, tapCount: 1)

        #expect(view.softwareLockedModifiers.isEmpty)
        #expect(flagEvents(from: events).last?.isEmpty == true)
    }

    private func keyDownEvents(from events: [MirageInputEvent]) -> [MirageKeyEvent] {
        events.compactMap { event in
            if case let .keyDown(keyEvent) = event {
                return keyEvent
            }
            return nil
        }
    }

    private func flagEvents(from events: [MirageInputEvent]) -> [MirageModifierFlags] {
        events.compactMap { event in
            if case let .flagsChanged(modifiers) = event {
                return modifiers
            }
            return nil
        }
    }
}

private extension SoftwareModifierKey {
    static let commandKey = SoftwareModifierKey(title: "Cmd", modifier: .command)
    static let optionKey = SoftwareModifierKey(title: "Option", modifier: .option)
}
#endif
