//
//  HostLightsOutHotKeyRegistrar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//
//  Carbon global hotkey registration for Lights Out recovery.
//

import Carbon.HIToolbox
import Foundation
import MirageKit

#if os(macOS)
@MainActor
protocol HostLightsOutHotKeyRegistering: AnyObject {
    var onTrigger: (@MainActor () -> Void)? { get set }
    var registeredShortcut: MirageClientShortcutBinding? { get }

    @discardableResult
    func register(shortcut: MirageClientShortcutBinding) -> Bool
    func unregister()
}

struct HostLightsOutHotKeyRegistrationRequest: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
}

@MainActor
final class HostLightsOutHotKeyRegistrar: HostLightsOutHotKeyRegistering {
    var onTrigger: (@MainActor () -> Void)?
    private(set) var registeredShortcut: MirageClientShortcutBinding?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    @discardableResult
    func register(shortcut: MirageClientShortcutBinding) -> Bool {
        if registeredShortcut == shortcut, hotKeyRef != nil {
            return true
        }

        unregister()

        let request = Self.registrationRequest(for: shortcut)
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventSpec,
            userData,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            MirageLogger.host("Lights Out: failed to install hotkey handler (\(handlerStatus))")
            eventHandlerRef = nil
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        var nextHotKeyRef: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            request.keyCode,
            request.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &nextHotKeyRef
        )
        guard registrationStatus == noErr, let nextHotKeyRef else {
            MirageLogger.host(
                "Lights Out: failed to register hotkey \(shortcut.displayString) (\(registrationStatus))"
            )
            removeEventHandler()
            return false
        }

        hotKeyRef = nextHotKeyRef
        registeredShortcut = shortcut
        MirageLogger.host("Lights Out: registered emergency shortcut \(shortcut.displayString)")
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        registeredShortcut = nil
        removeEventHandler()
    }

    nonisolated static func registrationRequest(
        for shortcut: MirageClientShortcutBinding
    ) -> HostLightsOutHotKeyRegistrationRequest {
        HostLightsOutHotKeyRegistrationRequest(
            keyCode: UInt32(shortcut.keyCode),
            modifiers: carbonModifiers(for: shortcut.modifiers)
        )
    }

    nonisolated static func carbonModifiers(for modifiers: MirageModifierFlags) -> UInt32 {
        let normalizedModifiers = modifiers.normalizedForShortcutMatching
        var carbonModifiers: UInt32 = 0
        if normalizedModifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if normalizedModifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if normalizedModifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if normalizedModifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        return carbonModifiers
    }

    private func removeEventHandler() {
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
    }

    private func handleHotKey(id: EventHotKeyID) {
        guard id.signature == Self.hotKeySignature, id.id == Self.hotKeyID else { return }
        onTrigger?()
    }

    private nonisolated static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return status }

        let registrar = Unmanaged<HostLightsOutHotKeyRegistrar>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in
            registrar.handleHotKey(id: hotKeyID)
        }
        return noErr
    }

    private nonisolated static let hotKeyID: UInt32 = 1
    private nonisolated static let hotKeySignature: OSType = fourCharacterCode("MrLO")

    private nonisolated static func fourCharacterCode(_ string: String) -> OSType {
        let values = Array(string.utf8.prefix(4))
        guard values.count == 4 else { return 0 }
        return values.reduce(OSType(0)) { result, value in
            (result << 8) | OSType(value)
        }
    }
}
#endif
