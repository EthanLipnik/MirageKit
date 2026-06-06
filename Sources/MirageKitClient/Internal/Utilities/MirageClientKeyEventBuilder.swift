//
//  MirageClientKeyEventBuilder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
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
import Foundation

struct SoftwareKeyEvent: Equatable {
    let keyCode: UInt16
    let characters: String
    let charactersIgnoringModifiers: String
    let modifiers: MirageInput.MirageModifierFlags
}

enum MirageClientKeyEventBuilder {
    static let characterToMacKeyCodeMap: [String: UInt16] = [
        "a": 0x00,
        "b": 0x0B,
        "c": 0x08,
        "d": 0x02,
        "e": 0x0E,
        "f": 0x03,
        "g": 0x05,
        "h": 0x04,
        "i": 0x22,
        "j": 0x26,
        "k": 0x28,
        "l": 0x25,
        "m": 0x2E,
        "n": 0x2D,
        "o": 0x1F,
        "p": 0x23,
        "q": 0x0C,
        "r": 0x0F,
        "s": 0x01,
        "t": 0x11,
        "u": 0x20,
        "v": 0x09,
        "w": 0x0D,
        "x": 0x07,
        "y": 0x10,
        "z": 0x06,
        "1": 0x12,
        "2": 0x13,
        "3": 0x14,
        "4": 0x15,
        "5": 0x17,
        "6": 0x16,
        "7": 0x1A,
        "8": 0x1C,
        "9": 0x19,
        "0": 0x1D,
        ",": 0x2B,
        ".": 0x2F,
        "/": 0x2C,
        ";": 0x29,
        "'": 0x27,
        "[": 0x21,
        "]": 0x1E,
        "\\": 0x2A,
        "-": 0x1B,
        "=": 0x18,
        "`": 0x32,
        " ": 0x31,
        "\t": 0x30,
        "\n": 0x24,
    ]

    static let shiftedCharacterMap: [String: String] = [
        "!": "1",
        "@": "2",
        "#": "3",
        "$": "4",
        "%": "5",
        "^": "6",
        "&": "7",
        "*": "8",
        "(": "9",
        ")": "0",
        "_": "-",
        "+": "=",
        "{": "[",
        "}": "]",
        "|": "\\",
        ":": ";",
        "\"": "'",
        "<": ",",
        ">": ".",
        "?": "/",
        "~": "`",
    ]

    #if os(iOS) || os(visionOS)
    private static let keyCommandInputToMacKeyCodeMap: [String: UInt16] = [
        "\n": 0x24,
        "\r": 0x24,
        "\t": 0x30,
        " ": 0x31,
        "\u{8}": 0x33,
        "\u{7F}": 0x33,
        "UIKeyInputDelete": 0x33,
        "UIKeyInputEscape": 0x35,
        "UIKeyInputTab": 0x30,
        "UIKeyInputLeftArrow": 0x7B,
        "UIKeyInputRightArrow": 0x7C,
        "UIKeyInputDownArrow": 0x7D,
        "UIKeyInputUpArrow": 0x7E,
        "UIKeyInputDeleteForward": 0x75,
    ]
    #endif

    private static let nonTextHardwareKeyCodes: Set<UInt16> = [
        0x24, // Return
        0x30, // Tab
        0x33, // Delete
        0x35, // Escape
        0x73, // Home
        0x74, // Page Up
        0x75, // Forward Delete
        0x77, // End
        0x79, // Page Down
        0x7B, // Left Arrow
        0x7C, // Right Arrow
        0x7D, // Down Arrow
        0x7E, // Up Arrow
    ]

    static func characterToMacKeyCode(_ character: String) -> UInt16 {
        characterToMacKeyCodeMap[character.lowercased()] ?? 0x00
    }

    static func characterToMacKeyCodeIfKnown(_ character: String) -> UInt16? {
        characterToMacKeyCodeMap[character.lowercased()]
    }

    #if os(iOS) || os(visionOS)
    static func keyCommandInputToMacKeyCode(_ input: String) -> UInt16? {
        keyCommandInputToMacKeyCodeMap[input]
    }
    #endif

    static func softwareKeyEvent(
        for character: String,
        baseModifiers: MirageInput.MirageModifierFlags
    ) -> SoftwareKeyEvent? {
        var modifiers = baseModifiers
        var charactersIgnoring = character
        let lowercased = character.lowercased()

        if let shifted = shiftedCharacterMap[character] {
            modifiers.insert(.shift)
            charactersIgnoring = shifted
            let keyCode = characterToMacKeyCode(shifted)
            return SoftwareKeyEvent(
                keyCode: keyCode,
                characters: character,
                charactersIgnoringModifiers: shifted,
                modifiers: modifiers
            )
        }

        if character != lowercased {
            modifiers.insert(.shift)
            charactersIgnoring = lowercased
        }

        guard let keyCode = characterToMacKeyCodeIfKnown(lowercased) else {
            return SoftwareKeyEvent(
                keyCode: MirageInput.MirageKeyEvent.unicodeScalarFallbackKeyCode,
                characters: character,
                charactersIgnoringModifiers: character,
                modifiers: baseModifiers
            )
        }

        return SoftwareKeyEvent(
            keyCode: keyCode,
            characters: character,
            charactersIgnoringModifiers: charactersIgnoring,
            modifiers: modifiers
        )
    }

    static func hardwareKeyEvent(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: MirageInput.MirageModifierFlags,
        isRepeat: Bool = false
    ) -> MirageInput.MirageKeyEvent {
        let normalizedCharacters = normalizedHardwareCharacters(characters)
        let normalizedCharactersIgnoringModifiers = normalizedHardwareCharacters(charactersIgnoringModifiers)

        if shouldUseUnicodeFallbackForHardwareKey(
            keyCode: keyCode,
            characters: normalizedCharacters,
            modifiers: modifiers
        ) {
            return MirageInput.MirageKeyEvent(
                keyCode: MirageInput.MirageKeyEvent.unicodeScalarFallbackKeyCode,
                characters: normalizedCharacters,
                charactersIgnoringModifiers: normalizedCharactersIgnoringModifiers ?? normalizedCharacters,
                modifiers: modifiers,
                isRepeat: isRepeat
            )
        }

        return MirageInput.MirageKeyEvent(
            keyCode: keyCode,
            characters: normalizedCharacters,
            charactersIgnoringModifiers: normalizedCharactersIgnoringModifiers,
            modifiers: modifiers,
            isRepeat: isRepeat
        )
    }

    static func shouldUseUnicodeFallbackForHardwareKey(
        keyCode: UInt16,
        characters: String?,
        modifiers: MirageInput.MirageModifierFlags
    ) -> Bool {
        if nonTextHardwareKeyCodes.contains(keyCode) { return false }
        guard let characters, isPrintableText(characters) else { return false }
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        if modifiers.contains(.option) { return true }
        guard let represented = characterToMacKeyCodeIfKnown(characters.lowercased()) else {
            return true
        }
        return represented != keyCode
    }

    private static func normalizedHardwareCharacters(_ string: String?) -> String? {
        guard let string else { return nil }
        if string.hasPrefix("UIKeyInput") { return nil }
        return string
    }

    private static func isPrintableText(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        return string.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}
