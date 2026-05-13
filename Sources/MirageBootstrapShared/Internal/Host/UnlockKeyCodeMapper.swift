//
//  UnlockKeyCodeMapper.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Carbon.HIToolbox
import Foundation

#if os(macOS)

enum UnlockKeyCodeMapper {
    static func keyCode(for char: Character) -> (keyCode: UInt16, needsShift: Bool)? {
        let charString = String(char)

        if let num = Int(charString), num >= 0, num <= 9 {
            let codes: [UInt16] = [
                UInt16(kVK_ANSI_0), UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4),
                UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9),
            ]
            return (codes[num], false)
        }

        guard let lowerChar = char.lowercased().first else {
            return nil
        }
        let needsShift = char.isUppercase

        let letterCodes: [Character: UInt16] = [
            "a": UInt16(kVK_ANSI_A), "b": UInt16(kVK_ANSI_B), "c": UInt16(kVK_ANSI_C), "d": UInt16(kVK_ANSI_D),
            "e": UInt16(kVK_ANSI_E), "f": UInt16(kVK_ANSI_F), "g": UInt16(kVK_ANSI_G), "h": UInt16(kVK_ANSI_H),
            "i": UInt16(kVK_ANSI_I), "j": UInt16(kVK_ANSI_J), "k": UInt16(kVK_ANSI_K), "l": UInt16(kVK_ANSI_L),
            "m": UInt16(kVK_ANSI_M), "n": UInt16(kVK_ANSI_N), "o": UInt16(kVK_ANSI_O), "p": UInt16(kVK_ANSI_P),
            "q": UInt16(kVK_ANSI_Q), "r": UInt16(kVK_ANSI_R), "s": UInt16(kVK_ANSI_S), "t": UInt16(kVK_ANSI_T),
            "u": UInt16(kVK_ANSI_U), "v": UInt16(kVK_ANSI_V), "w": UInt16(kVK_ANSI_W), "x": UInt16(kVK_ANSI_X),
            "y": UInt16(kVK_ANSI_Y), "z": UInt16(kVK_ANSI_Z),
        ]

        if let code = letterCodes[lowerChar] {
            return (code, needsShift)
        }

        let specialCodes: [Character: (UInt16, Bool)] = [
            " ": (UInt16(kVK_Space), false),
            "-": (UInt16(kVK_ANSI_Minus), false),
            "=": (UInt16(kVK_ANSI_Equal), false),
            "[": (UInt16(kVK_ANSI_LeftBracket), false),
            "]": (UInt16(kVK_ANSI_RightBracket), false),
            "\\": (UInt16(kVK_ANSI_Backslash), false),
            ";": (UInt16(kVK_ANSI_Semicolon), false),
            "'": (UInt16(kVK_ANSI_Quote), false),
            ",": (UInt16(kVK_ANSI_Comma), false),
            ".": (UInt16(kVK_ANSI_Period), false),
            "/": (UInt16(kVK_ANSI_Slash), false),
            "`": (UInt16(kVK_ANSI_Grave), false),
            "!": (UInt16(kVK_ANSI_1), true),
            "@": (UInt16(kVK_ANSI_2), true),
            "#": (UInt16(kVK_ANSI_3), true),
            "$": (UInt16(kVK_ANSI_4), true),
            "%": (UInt16(kVK_ANSI_5), true),
            "^": (UInt16(kVK_ANSI_6), true),
            "&": (UInt16(kVK_ANSI_7), true),
            "*": (UInt16(kVK_ANSI_8), true),
            "(": (UInt16(kVK_ANSI_9), true),
            ")": (UInt16(kVK_ANSI_0), true),
            "_": (UInt16(kVK_ANSI_Minus), true),
            "+": (UInt16(kVK_ANSI_Equal), true),
            "{": (UInt16(kVK_ANSI_LeftBracket), true),
            "}": (UInt16(kVK_ANSI_RightBracket), true),
            "|": (UInt16(kVK_ANSI_Backslash), true),
            ":": (UInt16(kVK_ANSI_Semicolon), true),
            "\"": (UInt16(kVK_ANSI_Quote), true),
            "<": (UInt16(kVK_ANSI_Comma), true),
            ">": (UInt16(kVK_ANSI_Period), true),
            "?": (UInt16(kVK_ANSI_Slash), true),
            "~": (UInt16(kVK_ANSI_Grave), true),
        ]

        return specialCodes[char]
    }
}

#endif
