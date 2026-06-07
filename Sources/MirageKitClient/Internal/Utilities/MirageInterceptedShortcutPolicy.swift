import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
//
//  MirageInterceptedShortcutPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//


enum MirageInterceptedShortcutDeliveryBehavior: Equatable {
    case single
    case repeatable
}

struct MirageInterceptedShortcut: Equatable {
    let input: String
    let keyCode: UInt16
    let modifiers: MirageInput.MirageModifierFlags
    let deliveryBehavior: MirageInterceptedShortcutDeliveryBehavior

    func forwardedModifiers(baseModifiers: MirageInput.MirageModifierFlags) -> MirageInput.MirageModifierFlags {
        baseModifiers.union(modifiers)
    }

    func keyDownEvent(
        baseModifiers: MirageInput.MirageModifierFlags,
        isRepeat: Bool = false
    ) -> MirageInput.MirageKeyEvent {
        MirageInput.MirageKeyEvent(
            keyCode: keyCode,
            characters: input,
            charactersIgnoringModifiers: input,
            modifiers: forwardedModifiers(baseModifiers: baseModifiers),
            isRepeat: isRepeat
        )
    }

    func keyUpEvent(baseModifiers: MirageInput.MirageModifierFlags) -> MirageInput.MirageKeyEvent {
        MirageInput.MirageKeyEvent(
            keyCode: keyCode,
            characters: input,
            charactersIgnoringModifiers: input,
            modifiers: forwardedModifiers(baseModifiers: baseModifiers)
        )
    }
}

enum MirageInterceptedShortcutPolicy {
    private static let commandWShortcut = makeShortcut("w", modifiers: [.command])
    private static let commandQShortcut = makeShortcut("q", modifiers: [.command])
    private static let commandHShortcut = makeShortcut("h", modifiers: [.command])
    private static let commandMShortcut = makeShortcut("m", modifiers: [.command])
    private static let commandCommaShortcut = makeShortcut(",", modifiers: [.command])
    private static let commandSpaceShortcut = makeShortcut(" ", modifiers: [.command])
    private static let commandTabShortcut = makeShortcut("\t", modifiers: [.command])
    private static let commandShiftTabShortcut = makeShortcut("\t", modifiers: [.command, .shift])
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
    private static let commandXShortcut = makeShortcut("x", modifiers: [.command])
    private static let commandCShortcut = makeShortcut("c", modifiers: [.command])
    private static let commandVShortcut = makeShortcut("v", modifiers: [.command])
    private static let commandShiftVShortcut = makeShortcut("v", modifiers: [.command, .shift])

    private static let shortcutsByActionName: [String: MirageInterceptedShortcut] = [
        "undo:": undoShortcut,
        "redo:": redoShortcut,
        "toggleBoldface:": commandBShortcut,
        "toggleItalics:": commandIShortcut,
        "toggleUnderline:": commandUShortcut,
        "find:": commandFShortcut,
        "findAndReplace:": commandShiftFShortcut,
        "findNext:": commandGShortcut,
        "findPrevious:": commandShiftGShortcut,
        "selectAll:": commandAShortcut,
        "paste:": commandVShortcut,
        "print:": commandPShortcut,
        "printContent:": commandPShortcut,
    ]

    static let shortcuts: [MirageInterceptedShortcut] = [
        commandWShortcut,
        commandQShortcut,
        commandHShortcut,
        commandMShortcut,
        commandCommaShortcut,
        commandSpaceShortcut,
        commandTabShortcut,
        commandShiftTabShortcut,
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
        commandXShortcut,
        commandCShortcut,
        commandVShortcut,
        commandShiftVShortcut,
    ]

    static func shortcut(
        input: String,
        modifiers: MirageInput.MirageModifierFlags
    ) -> MirageInterceptedShortcut? {
        let normalizedInput = input.lowercased()
        let normalizedModifiers = modifiers.normalizedForShortcutMatching
        return shortcuts.first { shortcut in
            shortcut.input == normalizedInput && shortcut.modifiers == normalizedModifiers
        }
    }

    #if os(iOS) || os(visionOS)
    /// Finds a host-forwarded shortcut by the macOS virtual key code emitted by hardware-key paths.
    static func shortcut(
        keyCode: UInt16,
        modifiers: MirageInput.MirageModifierFlags
    ) -> MirageInterceptedShortcut? {
        let normalizedModifiers = modifiers.normalizedForShortcutMatching
        return shortcuts.first { shortcut in
            shortcut.keyCode == keyCode && shortcut.modifiers == normalizedModifiers
        }
    }
    #endif

    static func shortcut(actionName: String) -> MirageInterceptedShortcut? {
        shortcutsByActionName[actionName]
    }

    private static func makeShortcut(
        _ input: String,
        modifiers: MirageInput.MirageModifierFlags,
        deliveryBehavior: MirageInterceptedShortcutDeliveryBehavior = .single
    ) -> MirageInterceptedShortcut {
        MirageInterceptedShortcut(
            input: input.lowercased(),
            keyCode: MirageClientKeyEventBuilder.characterToMacKeyCode(input),
            modifiers: modifiers.normalizedForShortcutMatching,
            deliveryBehavior: deliveryBehavior
        )
    }
}
