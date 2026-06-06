//
//  InputCapturingView+HardwareKeyboardCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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
#if canImport(GameController)
import Foundation
import GameController
import UIKit

extension InputCapturingView {
    /// GameController key codes that represent hardware keyboard modifiers.
    static let hardwareModifierKeyCodes: Set<GCKeyCode> = [
        .leftShift,
        .rightShift,
        .leftControl,
        .rightControl,
        .leftAlt,
        .rightAlt,
        .leftGUI,
        .rightGUI,
        .capsLock,
    ]
}

/// Shares the GameController hardware-keyboard callback across active input-capturing views.
@MainActor
final class HardwareKeyboardCoordinator {
    static let shared = HardwareKeyboardCoordinator()

    private let views = NSHashTable<InputCapturingView>.weakObjects()
    private var installedKeyboardInputID: ObjectIdentifier?

    /// Registers a view for hardware-keyboard modifier and shortcut recovery events.
    func register(_ view: InputCapturingView) {
        views.add(view)
        installHandlerIfNeeded()
    }

    /// Removes a view from hardware-keyboard recovery dispatch.
    func unregister(_ view: InputCapturingView) {
        views.remove(view)
    }

    /// Allows the next keyboard connection to install a fresh GameController handler.
    func handleKeyboardDisconnect() {
        installedKeyboardInputID = nil
    }

    private func installHandlerIfNeeded() {
        guard let keyboardInput = GCKeyboard.coalesced?.keyboardInput else { return }
        let inputID = ObjectIdentifier(keyboardInput)
        guard installedKeyboardInputID != inputID else { return }

        keyboardInput.keyChangedHandler = { [weak self] keyboardInput, _, keyCode, isPressed in
            let isModifier = InputCapturingView.hardwareModifierKeyCodes.contains(keyCode)
            if !isModifier, isPressed {
                // Fast path: skip non-modifier key-down when no modifiers are held.
                // handleGCKeyEvent would return early anyway, and creating Tasks for
                // every key press interferes with UIKit's pressesBegan delivery.
                let anyModifierHeld =
                    keyboardInput.button(forKeyCode: .leftGUI)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .rightGUI)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .leftShift)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .rightShift)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .leftControl)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .rightControl)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .leftAlt)?.isPressed == true ||
                    keyboardInput.button(forKeyCode: .rightAlt)?.isPressed == true
                guard anyModifierHeld else { return }
            }
            Task { @MainActor [weak self] in
                if isModifier {
                    self?.handleModifierKeyChange()
                } else {
                    self?.handleNonModifierKeyChange(keyCode: keyCode, isPressed: isPressed)
                }
            }
        }

        installedKeyboardInputID = inputID
    }

    private func handleModifierKeyChange() {
        for view in views.allObjects {
            guard view.window?.isKeyWindow == true else { continue }
            guard view.refreshModifierStateFromHardware() else { continue }
            guard view.recoverFirstResponderForGCShortcutModifierIfNeeded() else { continue }

            if view.heldModifierKeys.isEmpty { view.stopModifierRefresh() } else {
                view.startModifierRefreshIfNeeded()
            }
        }
    }

    private func handleNonModifierKeyChange(keyCode: GCKeyCode, isPressed: Bool) {
        for view in views.allObjects {
            guard view.window?.isKeyWindow == true else { continue }
            guard view.recoverFirstResponderForGCKeyIfNeeded(keyCode: keyCode, isPressed: isPressed) else {
                continue
            }
            view.handleGCKeyEvent(keyCode: keyCode, isPressed: isPressed)
        }
    }
}
#endif
#endif
