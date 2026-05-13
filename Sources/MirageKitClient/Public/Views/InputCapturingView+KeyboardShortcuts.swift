//
//  InputCapturingView+KeyboardShortcuts.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

#if os(iOS) || os(visionOS)
import UIKit
import MirageKit

private struct ShortcutCommandIdentity: Hashable {
    let input: String
    let modifiers: MirageModifierFlags
}

extension InputCapturingView {
    func editActionShortcut(
        for action: Selector
    ) -> MirageInterceptedShortcut? {
        MirageInterceptedShortcutPolicy.shortcut(
            actionName: NSStringFromSelector(action)
        )
    }

    func shouldSuppressClientShortcutDispatch(
        _ shortcut: MirageClientShortcut,
        source: ClientShortcutDispatchSource
    ) -> Bool {
        guard let lastDispatch = lastClientShortcutDispatch else { return false }
        guard lastDispatch.shortcut == shortcut else { return false }
        guard lastDispatch.source != source else { return false }
        return CFAbsoluteTimeGetCurrent() - lastDispatch.timestamp
            <= Self.passthroughShortcutDuplicateSuppressionWindow
    }

    func noteClientShortcutDispatch(
        _ shortcut: MirageClientShortcut,
        source: ClientShortcutDispatchSource
    ) {
        lastClientShortcutDispatch = ClientShortcutDispatch(
            shortcut: shortcut,
            source: source,
            timestamp: CFAbsoluteTimeGetCurrent()
        )
    }

    func performClientShortcut(
        _ shortcut: MirageClientShortcut,
        source: ClientShortcutDispatchSource
    ) {
        guard onClientShortcut != nil else { return }
        guard !shouldSuppressClientShortcutDispatch(shortcut, source: source) else {
            return
        }
        noteClientShortcutDispatch(shortcut, source: source)
        onClientShortcut?(shortcut)
    }

    func shouldSuppressPassthroughShortcutDispatch(
        _ shortcut: MirageInterceptedShortcut,
        source: PassthroughShortcutDispatchSource
    ) -> Bool {
        guard let lastDispatch = lastPassthroughShortcutDispatch else { return false }
        guard lastDispatch.shortcut == shortcut else { return false }
        guard lastDispatch.source != source else { return false }
        return CFAbsoluteTimeGetCurrent() - lastDispatch.timestamp
            <= Self.passthroughShortcutDuplicateSuppressionWindow
    }

    func notePassthroughShortcutDispatch(
        _ shortcut: MirageInterceptedShortcut,
        source: PassthroughShortcutDispatchSource
    ) {
        lastPassthroughShortcutDispatch = PassthroughShortcutDispatch(
            shortcut: shortcut,
            source: source,
            timestamp: CFAbsoluteTimeGetCurrent()
        )
    }

    func performPassthroughShortcut(
        _ shortcut: MirageInterceptedShortcut,
        source: PassthroughShortcutDispatchSource
    ) {
        guard onInputEvent != nil else { return }
        guard !shouldSuppressPassthroughShortcutDispatch(shortcut, source: source) else {
            return
        }
        notePassthroughShortcutDispatch(shortcut, source: source)
        syncModifiersForInput()

        if !startPassthroughShortcutRepeatIfNeeded(
            shortcut: shortcut,
            baseModifiers: keyboardModifiers
        ) {
            sendPassthroughShortcutKeyDown(
                shortcut: shortcut,
                baseModifiers: keyboardModifiers,
                isRepeat: false
            )
            sendPassthroughShortcutKeyUp(
                shortcut: shortcut,
                baseModifiers: keyboardModifiers
            )
        }

        syncModifiersForInput()
        updateModifierRefreshTimer()
    }

    func performResponderShortcutAction(_ action: Selector) {
        guard let shortcut = editActionShortcut(for: action) else { return }
        if let clientShortcut = clientShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) {
            performClientShortcut(clientShortcut, source: .responderAction)
            return
        }
        performPassthroughShortcut(shortcut, source: .responderAction)
    }

    /// Override keyCommands to claim iPadOS system shortcuts that would otherwise be
    /// handled locally instead of reaching the remote host.
    override public var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        var claimedShortcutCommands: Set<ShortcutCommandIdentity> = []

        for action in actions {
            guard let binding = action.shortcut else { continue }
            let asShortcut = MirageClientShortcut(binding)
            guard let input = keyCommandInput(for: asShortcut) else { continue }
            let identity = ShortcutCommandIdentity(
                input: input,
                modifiers: binding.modifiers.normalizedForShortcutMatching
            )
            guard claimedShortcutCommands.insert(identity).inserted else { continue }
            let command = UIKeyCommand(
                action: #selector(handleClientShortcutCommand(_:)),
                input: input,
                modifierFlags: Self.uiKeyModifierFlags(from: binding.modifiers)
            )
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }

        for shortcut in clientShortcuts {
            guard let input = keyCommandInput(for: shortcut) else { continue }
            let identity = ShortcutCommandIdentity(
                input: input,
                modifiers: shortcut.modifiers.normalizedForShortcutMatching
            )
            guard claimedShortcutCommands.insert(identity).inserted else { continue }
            let command = UIKeyCommand(
                action: #selector(handleClientShortcutCommand(_:)),
                input: input,
                modifierFlags: Self.uiKeyModifierFlags(from: shortcut.modifiers)
            )
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }

        for shortcut in MirageInterceptedShortcutPolicy.shortcuts {
            let identity = ShortcutCommandIdentity(
                input: shortcut.input,
                modifiers: shortcut.modifiers
            )
            guard claimedShortcutCommands.insert(identity).inserted else { continue }
            let command = UIKeyCommand(
                action: #selector(handlePassthroughShortcut(_:)),
                input: shortcut.input,
                modifierFlags: Self.uiKeyModifierFlags(from: shortcut.modifiers)
            )
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }

        return commands
    }

    override public func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if shouldHandleResponderAction(action) {
            return self
        }
        return super.target(forAction: action, withSender: sender)
    }

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if editActionShortcut(for: action) != nil {
            return shouldHandleResponderAction(action)
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc
    func handleClientShortcutCommand(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        guard let keyCode = MirageClientKeyEventBuilder.characterToMacKeyCodeIfKnown(input)
            ?? Self.keyCode(forKeyCommandInput: input) else {
            return
        }
        let modifiers = MirageModifierFlags(uiKeyModifierFlags: command.modifierFlags)
        if let action = matchingAction(keyCode: keyCode, modifiers: modifiers) {
            performAction(action, source: .keyCommand)
            return
        }
        guard let shortcut = clientShortcut(keyCode: keyCode, modifiers: modifiers) else {
            return
        }
        performClientShortcut(shortcut, source: .keyCommand)
    }

    @objc
    func handlePassthroughShortcut(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        guard let shortcut = MirageInterceptedShortcutPolicy.shortcut(
            input: input,
            modifiers: MirageModifierFlags(uiKeyModifierFlags: command.modifierFlags)
        ) else {
            return
        }

        performPassthroughShortcut(shortcut, source: .keyCommand)
    }

    /// Forwards the system bold shortcut to the remote host when the view owns key input.
    override public func toggleBoldface(_: Any?) {
        performResponderShortcutAction(#selector(toggleBoldface(_:)))
    }

    /// Forwards the system undo shortcut to the remote host when the view owns key input.
    @objc
    public func undo(_: Any?) {
        performResponderShortcutAction(#selector(undo(_:)))
    }

    /// Forwards the system redo shortcut to the remote host when the view owns key input.
    @objc
    public func redo(_: Any?) {
        performResponderShortcutAction(#selector(redo(_:)))
    }

    override public func toggleItalics(_: Any?) {
        performResponderShortcutAction(#selector(toggleItalics(_:)))
    }

    override public func toggleUnderline(_: Any?) {
        performResponderShortcutAction(#selector(toggleUnderline(_:)))
    }

    override public func find(_: Any?) {
        performResponderShortcutAction(#selector(find(_:)))
    }

    override public func findAndReplace(_: Any?) {
        performResponderShortcutAction(#selector(findAndReplace(_:)))
    }

    override public func findNext(_: Any?) {
        performResponderShortcutAction(#selector(findNext(_:)))
    }

    override public func findPrevious(_: Any?) {
        performResponderShortcutAction(#selector(findPrevious(_:)))
    }

    override public func selectAll(_: Any?) {
        performResponderShortcutAction(#selector(selectAll(_:)))
    }

    override public func printContent(_: Any?) {
        performResponderShortcutAction(#selector(printContent(_:)))
    }

    static func keyCode(forKeyCommandInput input: String) -> UInt16? {
        switch input {
        case UIKeyCommand.inputDelete:
            0x33
        case UIKeyCommand.inputEscape:
            0x35
        case UIKeyCommand.inputLeftArrow:
            0x7B
        case UIKeyCommand.inputRightArrow:
            0x7C
        case UIKeyCommand.inputDownArrow:
            0x7D
        case UIKeyCommand.inputUpArrow:
            0x7E
        default:
            MirageClientKeyEventBuilder.keyCommandInputToMacKeyCode(input)
        }
    }
}
#endif
