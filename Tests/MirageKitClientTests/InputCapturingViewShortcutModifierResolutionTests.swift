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

    @Test("Reported and tracked modifier snapshots are combined")
    func reportedAndTrackedModifierSnapshotsAreCombined() {
        let resolvedModifiers = InputCapturingView.resolvedHardwareKeyModifiers(
            reportedModifiers: [.command],
            trackedModifiers: [.shift]
        )

        #expect(
            MirageClientShortcut.normalizedShortcutModifiers(resolvedModifiers) == [.command, .shift]
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
}
#endif
