//
//  MirageClientKeyEventBuilder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//

import Foundation
import MirageKit

struct SoftwareKeyEvent: Equatable {
    let keyCode: UInt16
    let characters: String
    let charactersIgnoringModifiers: String
    let modifiers: MirageModifierFlags
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

    static func characterToMacKeyCode(_ character: String) -> UInt16 {
        characterToMacKeyCodeMap[character.lowercased()] ?? 0x00
    }

    static func characterToMacKeyCodeIfKnown(_ character: String) -> UInt16? {
        characterToMacKeyCodeMap[character.lowercased()]
    }

    static func softwareKeyEvent(
        for character: String,
        baseModifiers: MirageModifierFlags
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
                keyCode: MirageKeyEvent.unicodeScalarFallbackKeyCode,
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
}
