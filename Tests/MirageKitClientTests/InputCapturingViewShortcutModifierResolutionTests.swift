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

    @Test("Modified GC keyboard keys that are not shortcuts are forwarded to the host")
    func modifiedGCKeyboardKeysWithoutShortcutBindingsAreForwarded() {
        let decision = InputCapturingView.gcKeyboardKeyRoutingDecision(
            hasHeldModifiers: true,
            hasAction: false,
            hasClientShortcut: false,
            hasPassthroughShortcut: false
        )

        #expect(decision == .forwardKey)
    }
}
#endif
