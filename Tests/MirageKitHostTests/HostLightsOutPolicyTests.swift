//
//  HostLightsOutPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//

#if os(macOS)
import Carbon.HIToolbox
import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host Lights Out policy")
struct HostLightsOutPolicyTests {
    @Test("Input Monitoring is not required for active Lights Out workloads")
    func inputMonitoringIsNotRequiredForActiveWorkloads() {
        #expect(MirageHostService.shouldEnableLightsOut(
            hasAppStreams: true,
            hasDesktopStream: false,
            hasPendingAppStreamStart: false,
            hasPendingDesktopStreamStart: false,
            lightsOutEnabled: true
        ))
    }

    @Test("Unified desktop workloads activate when Lights Out is enabled")
    func unifiedDesktopWorkloadsActivateWhenLightsOutIsEnabled() {
        #expect(MirageHostService.shouldEnableLightsOut(
            hasAppStreams: false,
            hasDesktopStream: true,
            hasPendingAppStreamStart: false,
            hasPendingDesktopStreamStart: false,
            lightsOutEnabled: true
        ))
    }

    @Test("Disabled preference keeps Lights Out inactive")
    func disabledPreferenceKeepsLightsOutInactive() {
        #expect(!MirageHostService.shouldEnableLightsOut(
            hasAppStreams: true,
            hasDesktopStream: false,
            hasPendingAppStreamStart: false,
            hasPendingDesktopStreamStart: false,
            lightsOutEnabled: false
        ))
    }
}

@Suite("Host Lights Out shortcut")
struct HostLightsOutShortcutTests {
    @Test("Default shortcut matches client exit default")
    func defaultShortcutMatchesClientExitDefault() {
        let shortcut = MirageHostLightsOutShortcut.defaultEmergencyShortcut

        #expect(shortcut.keyCode == 0x35)
        #expect(shortcut.modifiers == [.control, .option])
        #expect(shortcut.displayString == "⌃⌥⎋")
    }

    @Test("Shortcut validation requires a modifier")
    func shortcutValidationRequiresModifier() {
        let shortcut = MirageClientShortcutBinding(keyCode: 0x35, modifiers: [])

        #expect(MirageHostLightsOutShortcut.validationError(for: shortcut) == .modifierRequired)
    }

    @Test("Shortcut validation rejects modifier-only keys")
    func shortcutValidationRejectsModifierOnlyKeys() {
        let shortcut = MirageClientShortcutBinding(keyCode: 0x3B, modifiers: [.control])

        #expect(MirageHostLightsOutShortcut.validationError(for: shortcut) == .nonModifierKeyRequired)
    }

    @Test("Carbon modifier mapping uses shortcut modifiers only")
    func carbonModifierMappingUsesShortcutModifiersOnly() {
        let modifiers = HostLightsOutHotKeyRegistrar.carbonModifiers(
            for: [.control, .option, .capsLock, .function]
        )

        #expect(modifiers == UInt32(controlKey | optionKey))
    }

    @Test("Registration request uses configured shortcut")
    func registrationRequestUsesConfiguredShortcut() {
        let shortcut = MirageClientShortcutBinding(keyCode: 0x0C, modifiers: [.command, .shift])
        let request = HostLightsOutHotKeyRegistrar.registrationRequest(for: shortcut)

        #expect(request.keyCode == 0x0C)
        #expect(request.modifiers == UInt32(cmdKey | shiftKey))
    }

    @Test("Overlay message shows configured shortcut")
    func overlayMessageShowsConfiguredShortcut() {
        let shortcut = MirageClientShortcutBinding(keyCode: 0x0C, modifiers: [.command, .shift])
        let message = HostLightsOutController.overlayMessage(for: shortcut)

        #expect(message == "Streaming with Mirage\nPress ⇧⌘Q to Force Stop Streams")
    }
}
#endif
