//
//  MirageInterceptedShortcutPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

import MirageKit

enum MirageInterceptedShortcutDeliveryBehavior: Equatable, Sendable {
    case single
    case repeatable
}

struct MirageInterceptedShortcut: Equatable, Sendable {
    let input: String
    let keyCode: UInt16
    let modifiers: MirageModifierFlags
    let deliveryBehavior: MirageInterceptedShortcutDeliveryBehavior

    var allowsRepeat: Bool {
        deliveryBehavior == .repeatable
    }

    func forwardedModifiers(baseModifiers: MirageModifierFlags) -> MirageModifierFlags {
        baseModifiers.union(modifiers)
    }

    func keyDownEvent(
        baseModifiers: MirageModifierFlags,
        isRepeat: Bool = false
    ) -> MirageKeyEvent {
        MirageKeyEvent(
            keyCode: keyCode,
            characters: input,
            charactersIgnoringModifiers: input,
            modifiers: forwardedModifiers(baseModifiers: baseModifiers),
            isRepeat: isRepeat
        )
    }

    func keyUpEvent(baseModifiers: MirageModifierFlags) -> MirageKeyEvent {
        MirageKeyEvent(
            keyCode: keyCode,
            characters: input,
            charactersIgnoringModifiers: input,
            modifiers: forwardedModifiers(baseModifiers: baseModifiers)
        )
    }
}

enum MirageInterceptedShortcutPolicy {
    private static let shortcutModifierMask: MirageModifierFlags = [
        .shift,
        .control,
        .option,
        .command,
    ]

    private static let commandWShortcut = makeShortcut("w", modifiers: [.command])
    private static let commandQShortcut = makeShortcut("q", modifiers: [.command])
    private static let commandHShortcut = makeShortcut("h", modifiers: [.command])
    private static let commandMShortcut = makeShortcut("m", modifiers: [.command])
    private static let commandCommaShortcut = makeShortcut(",", modifiers: [.command])
    private static let commandShiftWShortcut = makeShortcut("w", modifiers: [.command, .shift])
    private static let undoShortcut = makeShortcut(
        "z",
        modifiers: [.command],
        deliveryBehavior: .repeatable
    )
    private static let redoShortcut = makeShortcut(
        "z",
        modifiers: [.command, .shift],
        deliveryBehavior: .repeatable
    )
    private static let commandBShortcut = makeShortcut("b", modifiers: [.command])
    private static let commandIShortcut = makeShortcut("i", modifiers: [.command])
    private static let commandUShortcut = makeShortcut("u", modifiers: [.command])
    private static let commandFShortcut = makeShortcut("f", modifiers: [.command])
    private static let commandRShortcut = makeShortcut("r", modifiers: [.command])
    private static let commandGShortcut = makeShortcut("g", modifiers: [.command])
    private static let commandShiftFShortcut = makeShortcut("f", modifiers: [.command, .shift])
    private static let commandShiftGShortcut = makeShortcut("g", modifiers: [.command, .shift])
    private static let commandPShortcut = makeShortcut("p", modifiers: [.command])
    private static let commandNShortcut = makeShortcut("n", modifiers: [.command])
    private static let commandTShortcut = makeShortcut("t", modifiers: [.command])
    private static let commandLShortcut = makeShortcut("l", modifiers: [.command])
    private static let commandSShortcut = makeShortcut("s", modifiers: [.command])
    private static let commandAShortcut = makeShortcut("a", modifiers: [.command])

    private static let shortcutsByActionName: [String: MirageInterceptedShortcut] = [
        "undo:": undoShortcut,
        "redo:": redoShortcut,
        "toggleBoldface:": commandBShortcut,
        "toggleItalics:": commandIShortcut,
        "toggleUnderline:": commandUShortcut,
    ]

    static let shortcuts: [MirageInterceptedShortcut] = [
        commandWShortcut,
        commandQShortcut,
        commandHShortcut,
        commandMShortcut,
        commandCommaShortcut,
        commandShiftWShortcut,
        undoShortcut,
        redoShortcut,
        commandBShortcut,
        commandIShortcut,
        commandUShortcut,
        commandFShortcut,
        commandRShortcut,
        commandGShortcut,
        commandShiftFShortcut,
        commandShiftGShortcut,
        commandPShortcut,
        commandNShortcut,
        commandTShortcut,
        commandLShortcut,
        commandSShortcut,
        commandAShortcut,
    ]

    static func shortcut(
        input: String,
        modifiers: MirageModifierFlags
    ) -> MirageInterceptedShortcut? {
        let normalizedInput = input.lowercased()
        let normalizedModifiers = normalizedShortcutModifiers(modifiers)
        return shortcuts.first { shortcut in
            shortcut.input == normalizedInput && shortcut.modifiers == normalizedModifiers
        }
    }

    static func shortcut(
        keyCode: UInt16,
        modifiers: MirageModifierFlags
    ) -> MirageInterceptedShortcut? {
        let normalizedModifiers = normalizedShortcutModifiers(modifiers)
        return shortcuts.first { shortcut in
            shortcut.keyCode == keyCode && shortcut.modifiers == normalizedModifiers
        }
    }

    static func shortcut(actionName: String) -> MirageInterceptedShortcut? {
        shortcutsByActionName[actionName]
    }

    static func normalizedShortcutModifiers(_ modifiers: MirageModifierFlags) -> MirageModifierFlags {
        modifiers.intersection(shortcutModifierMask)
    }

    private static func makeShortcut(
        _ input: String,
        modifiers: MirageModifierFlags,
        deliveryBehavior: MirageInterceptedShortcutDeliveryBehavior = .single
    ) -> MirageInterceptedShortcut {
        MirageInterceptedShortcut(
            input: input.lowercased(),
            keyCode: MirageClientKeyEventBuilder.characterToMacKeyCode(input),
            modifiers: normalizedShortcutModifiers(modifiers),
            deliveryBehavior: deliveryBehavior
        )
    }
}
