//
//  InputCapturingViewShortcutModifierResolutionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

#if os(iOS) || os(visionOS)
@testable import MirageKitClient
import MirageKit
import Testing
import UIKit
import MirageInput

@Suite("Input capturing view shortcut modifier resolution")
struct InputCapturingViewShortcutModifierResolutionTests {
    @Test("Desktop exit shortcut still matches when Escape reports no modifiers")
    func desktopExitShortcutMatchesTrackedModifiers() {
        let resolvedModifiers = InputCapturingView.resolvedHardwareKeyModifiers(
            reportedModifiers: [],
            trackedModifiers: [.control, .option]
        )

        #expect(
            MirageClientShortcut.defaultDesktopExit.matches(
                MirageInput.MirageKeyEvent(
                    keyCode: MirageClientShortcut.defaultDesktopExit.keyCode,
                    modifiers: resolvedModifiers
                )
            )
        )
    }

    @Test("Modified GC keyboard keys that are not shortcuts use forward-key decision")
    func modifiedGCKeyboardKeysWithoutShortcutBindingsUseForwardKeyDecision() {
        let decision = InputCapturingView.gcKeyboardKeyRoutingDecision(
            hasHeldModifiers: true,
            hasAction: false,
            hasClientShortcut: false,
            hasPassthroughShortcut: false
        )

        #expect(decision == .forwardKey)
    }

    @Test("Option letter keys stay on UIKit path while Option+Space forwards")
    func optionLetterKeysStayOnUIKitPathWhileOptionSpaceForwards() {
        #expect(!InputCapturingView.shouldClaimGCForwardKey(modifiers: [.option]))
        #expect(InputCapturingView.shouldClaimGCForwardKey(modifiers: [.command]))
        #expect(InputCapturingView.shouldClaimGCForwardKey(modifiers: [.control]))
        #expect(!InputCapturingView.shouldClaimGCForwardKey(
            macKeyCode: 0x00,
            modifiers: [.option]
        ))
        #expect(InputCapturingView.shouldClaimGCForwardKey(
            macKeyCode: 0x31,
            modifiers: [.option]
        ))
    }

    @Test("GC keyboard first responder recovery allows registered Option shortcuts and Option+Space")
    func gcKeyboardFirstResponderRecoveryAllowsRegisteredOptionShortcutsAndOptionSpace() {
        #expect(InputCapturingView.shouldRecoverFirstResponderForGCKey(
            isPressed: true,
            macKeyCode: 0x31,
            modifiers: [.option],
            hasAction: false,
            hasClientShortcut: true,
            hasPassthroughShortcut: false
        ))
        #expect(InputCapturingView.shouldRecoverFirstResponderForGCKey(
            isPressed: true,
            macKeyCode: 0x31,
            modifiers: [.option],
            hasAction: true,
            hasClientShortcut: false,
            hasPassthroughShortcut: false
        ))
        #expect(InputCapturingView.shouldRecoverFirstResponderForGCKey(
            isPressed: true,
            macKeyCode: 0x31,
            modifiers: [.option],
            hasAction: false,
            hasClientShortcut: false,
            hasPassthroughShortcut: false
        ))
        #expect(!InputCapturingView.shouldRecoverFirstResponderForGCKey(
            isPressed: false,
            macKeyCode: 0x31,
            modifiers: [.option],
            hasAction: false,
            hasClientShortcut: true,
            hasPassthroughShortcut: false
        ))
        #expect(!InputCapturingView.shouldRecoverFirstResponderForGCKey(
            isPressed: true,
            macKeyCode: 0x00,
            modifiers: [.option],
            hasAction: false,
            hasClientShortcut: false,
            hasPassthroughShortcut: false
        ))
    }

    @Test("Unmodified GC keyboard character keys stay on UIKit responder path")
    func unmodifiedGCKeyboardCharacterKeysStayOnUIKitResponderPath() {
        let decision = InputCapturingView.gcKeyboardKeyRoutingDecision(
            hasHeldModifiers: false,
            hasAction: false,
            hasClientShortcut: false,
            hasPassthroughShortcut: false
        )

        #expect(decision == .ignore)
    }

    @Test("Control text-navigation shortcuts are repeat candidates while held")
    func controlTextNavigationShortcutsAreRepeatCandidatesWhileHeld() {
        let keyCodes: [UInt16] = [
            0x04, // H
            0x03, // F
            0x2D, // N
            0x0B, // B
            0x23, // P
        ]

        for keyCode in keyCodes {
            let keyEvent = MirageInput.MirageKeyEvent(keyCode: keyCode, modifiers: .control)
            let repeatEvent = InputCapturingView.modifiedKeyRepeatEvent(for: keyEvent)

            #expect(repeatEvent.keyCode == keyCode)
            #expect(repeatEvent.modifiers == .control)
            #expect(repeatEvent.isRepeat)
            #expect(InputCapturingView.shouldContinueModifiedKeyRepeat(
                keyIsPressed: true,
                currentModifiers: .control,
                requiredModifiers: .control
            ))
        }
    }

    @Test("Modified key repeat stops when required modifier is released")
    func modifiedKeyRepeatStopsWhenRequiredModifierIsReleased() {
        #expect(!InputCapturingView.shouldContinueModifiedKeyRepeat(
            keyIsPressed: true,
            currentModifiers: [],
            requiredModifiers: .control
        ))
        #expect(!InputCapturingView.shouldContinueModifiedKeyRepeat(
            keyIsPressed: false,
            currentModifiers: .control,
            requiredModifiers: .control
        ))
        #expect(InputCapturingView.shouldContinueModifiedKeyRepeat(
            keyIsPressed: true,
            currentModifiers: [.control, .shift],
            requiredModifiers: .control
        ))
    }

    @Test("Modified key repeat key-up uses current modifiers without marking repeat")
    func modifiedKeyRepeatKeyUpUsesCurrentModifiersWithoutMarkingRepeat() {
        let initialEvent = MirageInput.MirageKeyEvent(
            keyCode: 0x04,
            characters: "h",
            charactersIgnoringModifiers: "h",
            modifiers: .control,
            isRepeat: true
        )

        let keyUp = InputCapturingView.modifiedKeyRepeatKeyUpEvent(
            for: initialEvent,
            modifiers: []
        )

        #expect(keyUp.keyCode == 0x04)
        #expect(keyUp.characters == "h")
        #expect(keyUp.charactersIgnoringModifiers == "h")
        #expect(keyUp.modifiers == [])
        #expect(!keyUp.isRepeat)
    }

    @Test("Key command registration normalizes Hyper shortcut modifiers")
    @MainActor
    func keyCommandRegistrationNormalizesHyperShortcutModifiers() throws {
        let view = InputCapturingView(frame: .zero)
        view.actions = [
            .customHostKeyBinding(
                id: "hyperEscape",
                displayName: "Hyper Escape",
                hostKeyEvent: MirageInput.MirageKeyEvent(keyCode: 0x35),
                shortcut: MirageInput.MirageClientShortcutBinding(
                    keyCode: 0x35,
                    modifiers: [.control, .option, .shift, .capsLock, .numericPad, .function]
                )
            ),
        ]

        let command = try #require(
            view.keyCommands?.first { $0.input == UIKeyCommand.inputEscape }
        )

        #expect(command.modifierFlags.contains(.control))
        #expect(command.modifierFlags.contains(.alternate))
        #expect(command.modifierFlags.contains(.shift))
        #expect(!command.modifierFlags.contains(.alphaShift))
        #expect(!command.modifierFlags.contains(.numericPad))
    }
}
#endif
