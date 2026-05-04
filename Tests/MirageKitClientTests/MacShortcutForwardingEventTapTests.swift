//
//  MacShortcutForwardingEventTapTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//

#if os(macOS)
@testable import MirageKitClient
import MirageKit
import Testing

@Suite("Mac shortcut forwarding event tap")
struct MacShortcutForwardingEventTapTests {
    @Test("Screenshot shortcuts are forwarded")
    func screenshotShortcutsAreForwarded() {
        #expect(MacShortcutForwardingEventTap.shouldForwardShortcut(
            keyCode: 0x14,
            modifiers: [.command, .shift]
        ))
        #expect(MacShortcutForwardingEventTap.shouldForwardShortcut(
            keyCode: 0x15,
            modifiers: [.command, .shift, .control]
        ))
        #expect(MacShortcutForwardingEventTap.shouldForwardShortcut(
            keyCode: 0x17,
            modifiers: [.command, .shift, .option]
        ))
    }

    @Test("Shortcut-style keys are forwarded without claiming ordinary typing")
    func shortcutStyleKeysAreForwardedWithoutClaimingTyping() {
        #expect(MacShortcutForwardingEventTap.shouldForwardShortcut(
            keyCode: 0x0C,
            modifiers: [.command]
        ))
        #expect(MacShortcutForwardingEventTap.shouldForwardShortcut(
            keyCode: 0x00,
            modifiers: [.control]
        ))
        #expect(!MacShortcutForwardingEventTap.shouldForwardShortcut(
            keyCode: 0x00,
            modifiers: []
        ))
        #expect(!MacShortcutForwardingEventTap.shouldForwardShortcut(
            keyCode: 0x00,
            modifiers: [.shift]
        ))
    }
}
#endif
