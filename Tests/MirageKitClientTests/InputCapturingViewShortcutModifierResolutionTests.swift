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
                MirageKeyEvent(
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

    @Test("GC keyboard first responder recovery is limited to command-style key down")
    func gcKeyboardFirstResponderRecoveryIsLimitedToCommandStyleKeyDown() {
        #expect(InputCapturingView.shouldRecoverFirstResponderForGCShortcutModifiers(
            modifiers: [.command]
        ))
        #expect(InputCapturingView.shouldRecoverFirstResponderForGCShortcutModifiers(
            modifiers: [.control]
        ))
        #expect(!InputCapturingView.shouldRecoverFirstResponderForGCShortcutModifiers(
            modifiers: [.shift]
        ))
        #expect(!InputCapturingView.shouldRecoverFirstResponderForGCShortcutModifiers(
            modifiers: [.option]
        ))
        #expect(InputCapturingView.shouldRecoverFirstResponderForGCForwardKey(
            isPressed: true,
            modifiers: [.command]
        ))
        #expect(InputCapturingView.shouldRecoverFirstResponderForGCForwardKey(
            isPressed: true,
            modifiers: [.control]
        ))
        #expect(!InputCapturingView.shouldRecoverFirstResponderForGCForwardKey(
            isPressed: true,
            modifiers: [.option]
        ))
        #expect(!InputCapturingView.shouldRecoverFirstResponderForGCForwardKey(
            isPressed: false,
            modifiers: [.command]
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

    @Test("Key command registration normalizes Hyper shortcut modifiers")
    @MainActor
    func keyCommandRegistrationNormalizesHyperShortcutModifiers() throws {
        let view = InputCapturingView(frame: .zero)
        view.actions = [
            .customHostKeyBinding(
                id: "hyperEscape",
                displayName: "Hyper Escape",
                hostKeyEvent: MirageKeyEvent(keyCode: 0x35),
                shortcut: MirageClientShortcutBinding(
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
