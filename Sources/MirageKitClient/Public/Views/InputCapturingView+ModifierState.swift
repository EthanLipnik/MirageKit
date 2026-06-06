//
//  InputCapturingView+ModifierState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(iOS) || os(visionOS)
import UIKit
#if canImport(GameController)
import GameController
#endif

// MARK: - Modifier State

extension InputCapturingView {
    /// Get current modifier state from held keyboard keys
    var keyboardModifiers: MirageInput.MirageModifierFlags {
        var modifiers: MirageInput.MirageModifierFlags = []
        for keyCode in heldModifierKeys {
            if let modifier = Self.modifierKeyMap[keyCode] { modifiers.insert(modifier) }
        }
        if capsLockEnabled { modifiers.insert(.capsLock) }
        modifiers.formUnion(softwareHeldModifiers)
        return modifiers
    }

    func sendModifierStateIfNeeded(force: Bool = false) {
        let modifiers = keyboardModifiers
        guard force || modifiers != lastSentModifiers else { return }
        lastSentModifiers = modifiers
        updateSoftwareModifierButtons()
        onInputEvent?(.flagsChanged(modifiers))
    }

    func refreshModifiersForInput() -> Bool {
        let hardwareAvailable = refreshModifierStateFromHardware()
        if hardwareAvailable { sendModifierSnapshotIfNeeded(keyboardModifiers) }
        return hardwareAvailable
    }

    func syncModifiersForInput() {
        _ = refreshModifiersForInput()
    }

    func sendModifierSnapshotIfNeeded(_ modifiers: MirageInput.MirageModifierFlags) {
        guard modifiers != lastSentModifiers else { return }
        lastSentModifiers = modifiers
        updateSoftwareModifierButtons()
        onInputEvent?(.flagsChanged(modifiers))
    }

    func recordSoftwareModifierSyncResult(visualUpdates: Int) {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        softwareModifierSyncRequestCount &+= 1
        if visualUpdates > 0 {
            softwareModifierVisualUpdateCount &+= UInt64(visualUpdates)
        }
        let now = CFAbsoluteTimeGetCurrent()
        if lastSoftwareModifierSyncLogTime == 0 {
            lastSoftwareModifierSyncLogTime = now
            return
        }
        guard now - lastSoftwareModifierSyncLogTime >= softwareModifierSyncLogInterval else {
            return
        }
        let requests = softwareModifierSyncRequestCount
        let visualUpdates = softwareModifierVisualUpdateCount
        softwareModifierSyncRequestCount = 0
        softwareModifierVisualUpdateCount = 0
        lastSoftwareModifierSyncLogTime = now
        MirageLogger.metrics(
            "Software modifier sync stats: requests=\(requests), visualUpdates=\(visualUpdates), windowSeconds=5"
        )
    }

    func logOnInputEventRebindSuppressionIfNeeded() {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if lastOnInputEventRebindLogTime == 0 {
            lastOnInputEventRebindLogTime = now
            return
        }
        guard now - lastOnInputEventRebindLogTime >= onInputEventRebindLogInterval else {
            return
        }
        let suppressedCount = suppressedOnInputEventRebindCount
        suppressedOnInputEventRebindCount = 0
        lastOnInputEventRebindLogTime = now
        MirageLogger.metrics(
            "Input callback rebind suppressed: count=\(suppressedCount), windowSeconds=5"
        )
    }

    func updateCapsLockState(from modifierFlags: UIKeyModifierFlags) {
        let isEnabled = modifierFlags.contains(.alphaShift)
        guard isEnabled != capsLockEnabled else { return }
        capsLockEnabled = isEnabled
        sendModifierStateIfNeeded(force: true)
    }

    func resyncModifierState(from modifierFlags: UIKeyModifierFlags) {
        let flags = MirageInput.MirageModifierFlags(uiKeyModifierFlags: modifierFlags)
        var newHeldKeys = Set<UIKeyboardHIDUsage>()
        for (flag, keys) in Self.modifierFlagToKeys where flags.contains(flag) {
            let existingKeys = keys.filter { heldModifierKeys.contains($0) }
            if existingKeys.isEmpty {
                if let primaryKey = keys.first { newHeldKeys.insert(primaryKey) }
            } else {
                newHeldKeys.formUnion(existingKeys)
            }
        }

        let newCapsLockEnabled = flags.contains(.capsLock)

        guard newHeldKeys != heldModifierKeys || newCapsLockEnabled != capsLockEnabled else { return }
        heldModifierKeys = newHeldKeys
        capsLockEnabled = newCapsLockEnabled
        sendModifierStateIfNeeded(force: true)
        stopModifiedKeyRepeatIfRequiredModifiersReleased()
        if heldModifierKeys.isEmpty { stopModifierRefresh() } else {
            startModifierRefreshIfNeeded()
        }
    }

    /// Clear all held modifiers with a snapshot update
    func resetAllModifiers() {
        guard !heldModifierKeys.isEmpty || !softwareHeldModifiers.isEmpty || capsLockEnabled || !lastSentModifiers
            .isEmpty else {
            return
        }
        stopModifierRefresh()
        heldModifierKeys.removeAll()
        softwareHeldModifiers = []
        capsLockEnabled = false
        #if canImport(GameController)
        gcClaimedKeyCodes.removeAll()
        clientShortcutClaimedKeyCodes.removeAll()
        passthroughClaimedKeyCodes.removeAll()
        #endif
        updateSoftwareModifierButtons()
        sendModifierStateIfNeeded(force: true)
    }

    func startModifierRefreshIfNeeded() {
        guard modifierRefreshTask == nil else { return }
        modifierRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if refreshModifierStateFromHardware() {
                    hardwareRefreshFailureCount = 0

                    // Always send heartbeat while modifiers are held.
                    // This keeps host timestamps fresh even when state is unchanged,
                    // preventing the host's 0.5s timeout from clearing held modifiers.
                    if !heldModifierKeys.isEmpty {
                        let modifiers = keyboardModifiers
                        lastSentModifiers = modifiers
                        onInputEvent?(.flagsChanged(modifiers))
                    }
                } else {
                    hardwareRefreshFailureCount += 1
                    if hardwareRefreshFailureCount >= 3 {
                        // Hardware unavailable, clear modifiers to prevent stuck state
                        MirageLogger.client("Hardware keyboard unavailable, clearing modifiers")
                        stopAllKeyRepeats()
                        resetAllModifiers()
                        modifierRefreshTask = nil
                        return
                    }
                }

                if heldModifierKeys.isEmpty {
                    modifierRefreshTask = nil
                    return
                }

                do {
                    try await Task.sleep(for: Self.modifierRefreshPollInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stopModifierRefresh() {
        modifierRefreshTask?.cancel()
        modifierRefreshTask = nil
    }

    func updateHardwareKeyboardPresence(_ isPresent: Bool) {
        guard hardwareKeyboardPresent != isPresent else { return }
        hardwareKeyboardPresent = isPresent
        onHardwareKeyboardPresenceChanged?(isPresent)
        requestResponderRecovery(.hardwareKeyboardPresenceChanged)
    }

    func refreshModifierStateFromHardware() -> Bool {
        #if canImport(GameController)
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else { return false }
        var refreshedKeys: Set<UIKeyboardHIDUsage> = []

        if keyboardInput.button(forKeyCode: .leftShift)?.isPressed == true { refreshedKeys.insert(.keyboardLeftShift) }
        if keyboardInput.button(forKeyCode: .rightShift)?.isPressed == true { refreshedKeys.insert(.keyboardRightShift) }
        if keyboardInput.button(forKeyCode: .leftControl)?.isPressed == true { refreshedKeys.insert(.keyboardLeftControl) }
        if keyboardInput.button(forKeyCode: .rightControl)?.isPressed == true { refreshedKeys.insert(.keyboardRightControl) }
        if keyboardInput.button(forKeyCode: .leftAlt)?.isPressed == true { refreshedKeys.insert(.keyboardLeftAlt) }
        if keyboardInput.button(forKeyCode: .rightAlt)?.isPressed == true { refreshedKeys.insert(.keyboardRightAlt) }
        if keyboardInput.button(forKeyCode: .leftGUI)?.isPressed == true { refreshedKeys.insert(.keyboardLeftGUI) }
        if keyboardInput.button(forKeyCode: .rightGUI)?.isPressed == true { refreshedKeys.insert(.keyboardRightGUI) }

        guard refreshedKeys != heldModifierKeys else { return true }
        heldModifierKeys = refreshedKeys
        sendModifierStateIfNeeded(force: true)
        stopModifiedKeyRepeatIfRequiredModifiersReleased()
        return true
        #else
        return false
        #endif
    }

    func syncModifierStateFromHardware() {
        _ = refreshModifierStateFromHardware()
    }

    #if canImport(GameController)
    func installHardwareKeyboardHandler() {
        HardwareKeyboardCoordinator.shared.register(self)
    }

    func uninstallHardwareKeyboardHandler() {
        HardwareKeyboardCoordinator.shared.unregister(self)
    }
    #endif

    /// Maximum time between taps to count as multi-click (in seconds)
    static let multiClickTimeThreshold: TimeInterval = 0.5
    /// Maximum distance between taps to count as multi-click (in view points)
    static let multiClickDistanceThresholdPoints: CGFloat = 12
    /// Maximum drift allowed before direct-touch long-press drag activation cancels.
    static let dragActivationMovementThresholdPoints: CGFloat = 10

    /// Modifier key HID codes and their corresponding flags
    static let modifierKeyMap: [UIKeyboardHIDUsage: MirageInput.MirageModifierFlags] = [
        .keyboardLeftShift: .shift,
        .keyboardRightShift: .shift,
        .keyboardLeftControl: .control,
        .keyboardRightControl: .control,
        .keyboardLeftAlt: .option,
        .keyboardRightAlt: .option,
        .keyboardLeftGUI: .command,
        .keyboardRightGUI: .command,
        .keyboardCapsLock: .capsLock,
    ]

    /// Preferred key codes for modifier flag resync (preserve left/right when possible)
    static let modifierFlagToKeys: [(flag: MirageInput.MirageModifierFlags, keys: [UIKeyboardHIDUsage])] = [
        (.shift, [.keyboardLeftShift, .keyboardRightShift]),
        (.control, [.keyboardLeftControl, .keyboardRightControl]),
        (.option, [.keyboardLeftAlt, .keyboardRightAlt]),
        (.command, [.keyboardLeftGUI, .keyboardRightGUI]),
    ]

    /// Initial delay before key repeat starts (matches macOS default)
    static let keyRepeatInitialDelay: TimeInterval = 0.5
    /// Interval between repeat events (matches macOS default ~30 chars/sec)
    static let keyRepeatInterval: TimeInterval = 0.033
    /// Polling interval for intercepted shortcut repeat sessions.
    static let passthroughShortcutRepeatPollInterval: TimeInterval = 1.0 / 60.0
    /// Window for suppressing duplicate delivery when UIKit invokes both keyCommand and
    /// responder edit-action paths for the same physical shortcut press.
    static let passthroughShortcutDuplicateSuppressionWindow: CFTimeInterval = 0.05
    /// Polling cadence for hardware modifier reconciliation while modifiers are held.
    static let modifierRefreshPollInterval: Duration = .milliseconds(100)
    static let pencilHoverMinimumInterval: CFTimeInterval = 1.0 / 120.0
    static let pencilHoverMinimumDistancePoints: CGFloat = 0.5

    #if canImport(GameController)
    struct ModifiedKeyRepeatState {
        let keyCode: GCKeyCode
        let keyEvent: MirageInput.MirageKeyEvent
        let requiredModifiers: MirageInput.MirageModifierFlags
        var nextRepeatDeadline: TimeInterval
    }
    #endif

    enum ClientShortcutDispatchSource {
        case hardwareKey
        case keyCommand
        case responderAction
    }

    struct ClientShortcutDispatch {
        let shortcut: MirageClientShortcut
        let source: ClientShortcutDispatchSource
        let timestamp: CFAbsoluteTime
    }

    enum PassthroughShortcutDispatchSource {
        case hardwareKey
        case keyCommand
        case responderAction
    }

    struct PassthroughShortcutDispatch {
        let shortcut: MirageInterceptedShortcut
        let source: PassthroughShortcutDispatchSource
        let timestamp: CFAbsoluteTime
    }
}

#endif
