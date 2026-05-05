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

    @Test("Option forward keys stay on UIKit path for layout text")
    func optionForwardKeysStayOnUIKitPathForLayoutText() {
        #expect(!InputCapturingView.shouldClaimGCForwardKey(modifiers: [.option]))
        #expect(InputCapturingView.shouldClaimGCForwardKey(modifiers: [.command]))
        #expect(InputCapturingView.shouldClaimGCForwardKey(modifiers: [.control]))
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
