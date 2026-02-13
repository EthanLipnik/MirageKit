//
//  LightsOutScreenshotShortcutTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Screenshot shortcut matching coverage for Lights Out suspension.
//

#if os(macOS)
import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Lights Out screenshot shortcuts")
struct LightsOutScreenshotShortcutTests {
    @Test
    func acceptsCommandShiftScreenshotKeys() {
        let required: MirageModifierFlags = [.command, .shift]
        #expect(HostLightsOutController.isScreenshotShortcut(keyCode: 0x14, modifiers: required))
        #expect(HostLightsOutController.isScreenshotShortcut(keyCode: 0x15, modifiers: required))
        #expect(HostLightsOutController.isScreenshotShortcut(keyCode: 0x17, modifiers: required))
    }

    @Test
    func rejectsMissingCommandOrShift() {
        #expect(!HostLightsOutController.isScreenshotShortcut(keyCode: 0x14, modifiers: [.command]))
        #expect(!HostLightsOutController.isScreenshotShortcut(keyCode: 0x14, modifiers: [.shift]))
    }

    @Test
    func acceptsOptionalControlOptionAndCapsLock() {
        let modifiers: MirageModifierFlags = [.command, .shift, .control, .option, .capsLock]
        #expect(HostLightsOutController.isScreenshotShortcut(keyCode: 0x17, modifiers: modifiers))
    }

    @Test
    func rejectsUnrelatedKeysAndDisallowedModifiers() {
        #expect(!HostLightsOutController.isScreenshotShortcut(keyCode: 0x00, modifiers: [.command, .shift]))
        #expect(!HostLightsOutController.isScreenshotShortcut(keyCode: 0x14, modifiers: [.command, .shift, .numericPad]))
    }
}
#endif
