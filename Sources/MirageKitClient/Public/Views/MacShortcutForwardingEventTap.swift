//
//  MacShortcutForwardingEventTap.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//

import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

final class MacShortcutForwardingEventTap {
    var onInputEvent: ((MirageInputEvent) -> Void)?
    var onForwardedShortcutKeyDown: (() -> Void)?
    var shouldForward: () -> Bool = { true }

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var forwardedKeyCodes: Set<UInt16> = []

    var isActive: Bool {
        eventTap != nil
    }

    func start() {
        guard eventTap == nil else { return }
        guard CGPreflightListenEventAccess() else {
            return
        }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let eventTap = Unmanaged<MacShortcutForwardingEventTap>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            return eventTap.handle(type: type, event: event)
        }

        let mask = (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            MirageLogger.client("Failed to create mac shortcut forwarding event tap")
            return
        }

        eventTap = tap
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        forwardedKeyCodes.removeAll()
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTapSource = nil
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            guard shouldForward() else { return Unmanaged.passUnretained(event) }
            return handleKeyDown(event)
        case .keyUp:
            guard shouldForward() else { return Unmanaged.passUnretained(event) }
            return handleKeyUp(event)
        case .flagsChanged:
            if shouldForward() {
                onInputEvent?(.flagsChanged(modifiers(from: event)))
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = keyCode(from: event)
        let modifiers = modifiers(from: event)
        guard Self.shouldForwardShortcut(keyCode: keyCode, modifiers: modifiers) else {
            return Unmanaged.passUnretained(event)
        }

        forwardedKeyCodes.insert(keyCode)
        onForwardedShortcutKeyDown?()
        onInputEvent?(.keyDown(keyEvent(from: event, modifiers: modifiers, isRepeat: isRepeat(event))))
        return nil
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = keyCode(from: event)
        guard forwardedKeyCodes.remove(keyCode) != nil else {
            return Unmanaged.passUnretained(event)
        }

        onInputEvent?(.keyUp(keyEvent(from: event, modifiers: modifiers(from: event), isRepeat: false)))
        return nil
    }

    private func keyEvent(
        from event: CGEvent,
        modifiers: MirageModifierFlags,
        isRepeat: Bool
    ) -> MirageKeyEvent {
        MirageKeyEvent(
            keyCode: keyCode(from: event),
            modifiers: modifiers,
            isRepeat: isRepeat
        )
    }

    private func keyCode(from event: CGEvent) -> UInt16 {
        UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
    }

    private func modifiers(from event: CGEvent) -> MirageModifierFlags {
        MirageModifierFlags(
            nsEventFlags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        )
    }

    private func isRepeat(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    }

    nonisolated static func shouldForwardShortcut(
        keyCode: UInt16,
        modifiers: MirageModifierFlags
    ) -> Bool {
        let shortcutModifiers = modifiers.normalizedForShortcutMatching
        guard !shortcutModifiers.isEmpty else { return false }
        if HostLightsOutScreenshotShortcutPolicy.isScreenshotShortcut(
            keyCode: keyCode,
            modifiers: modifiers
        ) {
            return true
        }
        return shortcutModifiers.contains(.command) ||
            shortcutModifiers.contains(.control) ||
            shortcutModifiers.contains(.option)
    }
}

private enum HostLightsOutScreenshotShortcutPolicy {
    nonisolated static func isScreenshotShortcut(
        keyCode: UInt16,
        modifiers: MirageModifierFlags
    ) -> Bool {
        let screenshotKeyCodes: Set<UInt16> = [0x14, 0x15, 0x17]
        guard screenshotKeyCodes.contains(keyCode) else { return false }
        guard modifiers.isSuperset(of: [.command, .shift]) else { return false }
        let allowed: MirageModifierFlags = [.command, .shift, .control, .option, .capsLock]
        return modifiers.subtracting(allowed).isEmpty
    }
}
#endif
