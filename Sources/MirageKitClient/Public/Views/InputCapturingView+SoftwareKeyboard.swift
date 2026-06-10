//
//  InputCapturingView+SoftwareKeyboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/31/26.
//
//  Software keyboard handling for streamed input.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    func setupSoftwareKeyboardField() {
        let inputView = SoftwareKeyboardInputView()
        inputView.translatesAutoresizingMaskIntoConstraints = false
        inputView.alpha = 0.01
        inputView.isUserInteractionEnabled = true
        inputView.backgroundColor = .clear
        inputView.isAccessibilityElement = false
        inputView.onInsertText = { [weak self] text in
            self?.handleSoftwareKeyboardInsertText(text)
        }
        inputView.onDeleteBackward = { [weak self] in
            self?.handleSoftwareKeyboardDeleteBackward()
        }
        inputView.onPaste = { [weak self] in
            self?.handleSoftwareKeyboardPaste()
        }
        inputView.onFirstResponderChanged = { [weak self] isFirstResponder in
            self?.handleSoftwareKeyboardResponderChange(isFirstResponder: isFirstResponder)
        }
        inputView.onAttachmentChanged = { [weak self] isAttached in
            guard isAttached else { return }
            self?.requestResponderRecovery(.didMoveToWindow)
        }

        let accessoryView = SoftwareKeyboardAccessoryView()
        accessoryView.onModifierToggle = { [weak self] key, isSelected in
            self?.toggleSoftwareModifier(key, isSelected: isSelected)
        }
        accessoryView.onDismissKeyboard = { [weak self] in
            self?.dismissSoftwareKeyboard()
        }
        #if os(visionOS)
        accessoryView.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.isHidden = true
        addSubview(accessoryView)
        NSLayoutConstraint.activate([
            accessoryView.leadingAnchor.constraint(equalTo: leadingAnchor),
            accessoryView.trailingAnchor.constraint(equalTo: trailingAnchor),
            accessoryView.bottomAnchor.constraint(equalTo: bottomAnchor),
            accessoryView.heightAnchor.constraint(equalToConstant: 44),
        ])
        #else
        inputView.inputAccessoryView = accessoryView
        #endif

        addSubview(inputView)
        NSLayoutConstraint.activate([
            inputView.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputView.topAnchor.constraint(equalTo: topAnchor),
            inputView.widthAnchor.constraint(equalToConstant: 1),
            inputView.heightAnchor.constraint(equalToConstant: 1),
        ])

        softwareKeyboardField = inputView
        softwareKeyboardAccessoryView = accessoryView
    }

    func updateSoftwareKeyboardVisibility(allowDismissalReset: Bool = false) {
        guard let inputView = softwareKeyboardField else { return }
        let wantsSoftwareKeyboard = softwareKeyboardVisible
        if allowDismissalReset,
           wantsSoftwareKeyboard,
           !softwareKeyboardDismissalPending,
           canPresentSoftwareKeyboardField(inputView) {
            softwareKeyboardDismissalPending = false
        }

        let shouldShow = wantsSoftwareKeyboard && !softwareKeyboardDismissalPending
        if shouldShow {
            guard canPresentSoftwareKeyboardField(inputView) else {
                logSoftwareKeyboardPresentation(
                    "presentation deferred",
                    didBecomeFirstResponder: nil
                )
                if !allowDismissalReset {
                    requestResponderRecovery(.focusChanged)
                }
                return
            }
            if !inputView.isFirstResponder {
                let didBecomeFirstResponder = inputView.becomeFirstResponder()
                logSoftwareKeyboardPresentation(
                    "presentation requested",
                    didBecomeFirstResponder: didBecomeFirstResponder
                )
                if !didBecomeFirstResponder && !allowDismissalReset {
                    requestResponderRecovery(.focusChanged)
                }
            }
            if inputView.isFirstResponder {
                inputView.reloadInputViews()
            }
        } else if inputView.isFirstResponder {
            inputView.resignFirstResponder()
        }
        #if os(visionOS)
        softwareKeyboardAccessoryView?.isHidden = !shouldShow
        #endif
    }

    func canPresentSoftwareKeyboardField(_ inputView: SoftwareKeyboardInputView) -> Bool {
        guard inputView.window === window,
              let window,
              window.isKeyWindow,
              window.windowScene?.activationState == .foregroundActive else {
            return false
        }
        return true
    }

    func clearSoftwareKeyboardState() {
        if softwareKeyboardField?.isFirstResponder == true {
            softwareKeyboardField?.resignFirstResponder()
        } else {
            handleSoftwareKeyboardResponderChange(isFirstResponder: false)
        }
        cancelPendingResponderRecovery()
    }

    func updateSoftwareModifierButtons() {
        let visualUpdates = softwareKeyboardAccessoryView?.setSelectedModifiers(softwareHeldModifiers) ?? 0
        recordSoftwareModifierSyncResult(visualUpdates: visualUpdates)
    }

    func toggleSoftwareModifier(_ key: SoftwareModifierKey, isSelected: Bool) {
        if isSelected { softwareHeldModifiers.insert(key.modifier) } else {
            softwareHeldModifiers.remove(key.modifier)
        }
        updateSoftwareModifierButtons()
        sendModifierStateIfNeeded(force: true)
    }

    func handleSoftwareKeyboardInsertText(_ text: String) {
        sendModifierStateIfNeeded(force: true)
        let modifiers = keyboardModifiers
        for scalar in text {
            let character = String(scalar)
            if character == "\n" {
                sendSoftwareKeyEvent(
                    keyCode: 0x24,
                    characters: "\n",
                    charactersIgnoringModifiers: "\n",
                    modifiers: modifiers
                )
                continue
            }
            guard let event = MirageClientKeyEventBuilder.softwareKeyEvent(
                for: character,
                baseModifiers: modifiers
            ) else { continue }
            sendSoftwareKeyEvent(
                keyCode: event.keyCode,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifiers: event.modifiers
            )
        }
    }

    func handleSoftwareKeyboardDeleteBackward() {
        sendModifierStateIfNeeded(force: true)
        let modifiers = keyboardModifiers
        sendSoftwareKeyEvent(keyCode: 0x33, characters: nil, charactersIgnoringModifiers: nil, modifiers: modifiers)
    }

    func handleSoftwareKeyboardPaste() {
        performResponderShortcutAction(#selector(paste(_:)))
    }

    func dismissSoftwareKeyboard() {
        softwareKeyboardDismissalPending = true
        if softwareKeyboardField?.isFirstResponder == true {
            softwareKeyboardField?.resignFirstResponder()
        } else {
            handleSoftwareKeyboardResponderChange(isFirstResponder: false)
        }
    }

    #if os(iOS)
    @objc
    func softwareKeyboardWillHide(_: Notification) {
        handleSoftwareKeyboardSystemHide()
    }

    func handleSoftwareKeyboardSystemHide() {
        guard softwareKeyboardVisible || isSoftwareKeyboardShown else { return }
        guard isSoftwareKeyboardResponderActive || isSoftwareKeyboardShown else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard window?.isKeyWindow == true else { return }
        guard window?.windowScene?.activationState == .foregroundActive else { return }

        if softwareKeyboardVisible && !softwareKeyboardDismissalPending {
            let streamIDText = streamID.map(String.init(describing:)) ?? "unbound"
            MirageLogger.client(
                "Software keyboard hide observed while requested: stream=\(streamIDText), scheduling recovery"
            )
            requestResponderRecovery(.focusChanged)
            return
        }

        softwareKeyboardDismissalPending = true
        cancelPendingResponderRecovery()
        notifySoftwareKeyboardVisibilityChanged(false)
    }
    #endif

    func handleSoftwareKeyboardResponderChange(isFirstResponder: Bool) {
        guard isSoftwareKeyboardResponderActive != isFirstResponder else { return }
        isSoftwareKeyboardResponderActive = isFirstResponder
        if isFirstResponder {
            softwareKeyboardDismissalPending = false
            notifySoftwareKeyboardVisibilityChanged(true)
            return
        }

        softwareHeldModifiers = []
        updateSoftwareModifierButtons()
        sendModifierStateIfNeeded(force: true)
        refreshCursorUpdates(force: true)
        if softwareKeyboardVisible && !softwareKeyboardDismissalPending {
            requestResponderRecovery(.focusChanged)
        } else {
            notifySoftwareKeyboardVisibilityChanged(false)
        }
    }

    func notifySoftwareKeyboardVisibilityChanged(_ isVisible: Bool) {
        guard isSoftwareKeyboardShown != isVisible else { return }
        isSoftwareKeyboardShown = isVisible
        let streamIDText = streamID.map(String.init(describing:)) ?? "unbound"
        MirageLogger.client(
            "Software keyboard visibility changed: stream=\(streamIDText), visible=\(isVisible), " +
                "responderActive=\(isSoftwareKeyboardResponderActive), hardwareKeyboardPresent=\(hardwareKeyboardPresent)"
        )
        onSoftwareKeyboardVisibilityChanged?(isVisible)
    }

    func logSoftwareKeyboardPresentation(
        _ event: String,
        didBecomeFirstResponder: Bool?
    ) {
        let streamIDText = streamID.map(String.init(describing:)) ?? "unbound"
        let sceneStateText = switch window?.windowScene?.activationState {
        case .foregroundActive:
            "foreground_active"
        case .foregroundInactive:
            "foreground_inactive"
        case .background:
            "background"
        case .unattached:
            "unattached"
        case nil:
            "nil"
        @unknown default:
            "unknown"
        }
        let didBecomeText = didBecomeFirstResponder.map(String.init(describing:)) ?? "nil"
        MirageLogger.client(
            "Software keyboard \(event): stream=\(streamIDText), " +
                "didBecomeFirstResponder=\(didBecomeText), " +
                "fieldIsFirstResponder=\(softwareKeyboardField?.isFirstResponder == true), " +
                "keyWindow=\(window?.isKeyWindow == true), " +
                "sceneState=\(sceneStateText), " +
                "hardwareKeyboardPresent=\(hardwareKeyboardPresent), " +
                "dismissalPending=\(softwareKeyboardDismissalPending)"
        )
    }

    func sendSoftwareKeyEvent(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: MirageModifierFlags
    ) {
        hideCursorForTypingUntilPointerMovement()
        let keyDown = MirageKeyEvent(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers
        )
        onInputEvent?(.keyDown(keyDown))

        let keyUp = MirageKeyEvent(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers
        )
        onInputEvent?(.keyUp(keyUp))
    }
}

struct SoftwareModifierKey: Hashable {
    let title: String
    let modifier: MirageModifierFlags
}
#endif
