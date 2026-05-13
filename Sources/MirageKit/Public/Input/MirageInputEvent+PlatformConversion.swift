//
//  MirageInputEvent+PlatformConversion.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//
//  Platform input conversion helpers for Mirage input events.
//

import Foundation

// MARK: - macOS CGEvent Conversion Extensions

#if os(macOS)
import AppKit
import Carbon.HIToolbox

public extension MirageMouseButton {
    /// Convert to CGMouseButton for CGEvent creation.
    var cgMouseButton: CGMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .button3,
             .button4,
             .middle: .center
        }
    }
}

public extension MirageModifierFlags {
    /// Convert to CGEventFlags for CGEvent creation.
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.numericPad) { flags.insert(.maskNumericPad) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// Create from NSEvent modifier flags.
    init(nsEventFlags: NSEvent.ModifierFlags) {
        var flags = MirageModifierFlags()
        if nsEventFlags.contains(.capsLock) { flags.insert(.capsLock) }
        if nsEventFlags.contains(.shift) { flags.insert(.shift) }
        if nsEventFlags.contains(.control) { flags.insert(.control) }
        if nsEventFlags.contains(.option) { flags.insert(.option) }
        if nsEventFlags.contains(.command) { flags.insert(.command) }
        if nsEventFlags.contains(.numericPad) { flags.insert(.numericPad) }
        if nsEventFlags.contains(.function) { flags.insert(.function) }
        self = flags
    }
}

public extension MirageScrollPhase {
    /// Create from NSEvent.Phase for scroll wheel events.
    init(from nsPhase: NSEvent.Phase) {
        switch nsPhase {
        case .began: self = .began
        case .changed: self = .changed
        case .stationary: self = .changed // Stationary still means active scrolling
        case .ended: self = .ended
        case .cancelled: self = .cancelled
        case .mayBegin: self = .mayBegin
        default: self = .none
        }
    }
}
#endif

// MARK: - iOS/iPadOS/visionOS UIKit Conversion Extensions

#if os(iOS) || os(visionOS)
import UIKit

public extension MirageModifierFlags {
    /// Create from UIKeyModifierFlags from an external keyboard.
    init(uiKeyModifierFlags: UIKeyModifierFlags) {
        var flags = MirageModifierFlags()
        if uiKeyModifierFlags.contains(.alphaShift) { flags.insert(.capsLock) }
        if uiKeyModifierFlags.contains(.shift) { flags.insert(.shift) }
        if uiKeyModifierFlags.contains(.control) { flags.insert(.control) }
        if uiKeyModifierFlags.contains(.alternate) { flags.insert(.option) }
        if uiKeyModifierFlags.contains(.command) { flags.insert(.command) }
        if uiKeyModifierFlags.contains(.numericPad) { flags.insert(.numericPad) }
        self = flags
    }
}

public extension MirageKeyEvent {
    /// Create from UIPress from an external keyboard.
    init?(press: UIPress, isRepeat: Bool = false) {
        guard let key = press.key else { return nil }

        let macKeyCode = Self.hidToMacKeyCode(key.keyCode)

        self.init(
            keyCode: macKeyCode,
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: MirageModifierFlags(uiKeyModifierFlags: key.modifierFlags),
            isRepeat: isRepeat
        )
    }

    /// Create from UIPress with explicit modifiers tracked outside the press event.
    init?(press: UIPress, modifiers: MirageModifierFlags, isRepeat: Bool = false) {
        guard let key = press.key else { return nil }

        let macKeyCode = Self.hidToMacKeyCode(key.keyCode)

        self.init(
            keyCode: macKeyCode,
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: modifiers,
            isRepeat: isRepeat
        )
    }

    /// Convert iOS HID usage code to macOS virtual key code.
    private static let hidToMacKeyCodeMap: [UIKeyboardHIDUsage: UInt16] = [
        .keyboardA: 0x00,
        .keyboardB: 0x0B,
        .keyboardC: 0x08,
        .keyboardD: 0x02,
        .keyboardE: 0x0E,
        .keyboardF: 0x03,
        .keyboardG: 0x05,
        .keyboardH: 0x04,
        .keyboardI: 0x22,
        .keyboardJ: 0x26,
        .keyboardK: 0x28,
        .keyboardL: 0x25,
        .keyboardM: 0x2E,
        .keyboardN: 0x2D,
        .keyboardO: 0x1F,
        .keyboardP: 0x23,
        .keyboardQ: 0x0C,
        .keyboardR: 0x0F,
        .keyboardS: 0x01,
        .keyboardT: 0x11,
        .keyboardU: 0x20,
        .keyboardV: 0x09,
        .keyboardW: 0x0D,
        .keyboardX: 0x07,
        .keyboardY: 0x10,
        .keyboardZ: 0x06,
        .keyboard1: 0x12,
        .keyboard2: 0x13,
        .keyboard3: 0x14,
        .keyboard4: 0x15,
        .keyboard5: 0x17,
        .keyboard6: 0x16,
        .keyboard7: 0x1A,
        .keyboard8: 0x1C,
        .keyboard9: 0x19,
        .keyboard0: 0x1D,
        .keyboardReturnOrEnter: 0x24,
        .keyboardEscape: 0x35,
        .keyboardDeleteOrBackspace: 0x33,
        .keyboardTab: 0x30,
        .keyboardSpacebar: 0x31,
        .keyboardCapsLock: 0x39,
        .keyboardHyphen: 0x1B,
        .keyboardEqualSign: 0x18,
        .keyboardOpenBracket: 0x21,
        .keyboardCloseBracket: 0x1E,
        .keyboardBackslash: 0x2A,
        .keyboardSemicolon: 0x29,
        .keyboardQuote: 0x27,
        .keyboardGraveAccentAndTilde: 0x32,
        .keyboardComma: 0x2B,
        .keyboardPeriod: 0x2F,
        .keyboardSlash: 0x2C,
        .keyboardF1: 0x7A,
        .keyboardF2: 0x78,
        .keyboardF3: 0x63,
        .keyboardF4: 0x76,
        .keyboardF5: 0x60,
        .keyboardF6: 0x61,
        .keyboardF7: 0x62,
        .keyboardF8: 0x64,
        .keyboardF9: 0x65,
        .keyboardF10: 0x6D,
        .keyboardF11: 0x67,
        .keyboardF12: 0x6F,
        .keyboardDeleteForward: 0x75,
        .keyboardHome: 0x73,
        .keyboardEnd: 0x77,
        .keyboardPageUp: 0x74,
        .keyboardPageDown: 0x79,
        .keyboardRightArrow: 0x7C,
        .keyboardLeftArrow: 0x7B,
        .keyboardDownArrow: 0x7D,
        .keyboardUpArrow: 0x7E,
        .keyboardLeftControl: 0x3B,
        .keyboardLeftShift: 0x38,
        .keyboardLeftAlt: 0x3A,
        .keyboardLeftGUI: 0x37,
        .keyboardRightControl: 0x3E,
        .keyboardRightShift: 0x3C,
        .keyboardRightAlt: 0x3D,
        .keyboardRightGUI: 0x36,
        .keypadNumLock: 0x47,
        .keypadSlash: 0x4B,
        .keypadAsterisk: 0x43,
        .keypadHyphen: 0x4E,
        .keypadPlus: 0x45,
        .keypadEnter: 0x4C,
        .keypad1: 0x53,
        .keypad2: 0x54,
        .keypad3: 0x55,
        .keypad4: 0x56,
        .keypad5: 0x57,
        .keypad6: 0x58,
        .keypad7: 0x59,
        .keypad8: 0x5B,
        .keypad9: 0x5C,
        .keypad0: 0x52,
        .keypadPeriod: 0x41,
        .keypadEqualSign: 0x51,
    ]

    /// Maps a UIKit HID usage to the equivalent macOS virtual key code.
    static func hidToMacKeyCode(_ hidCode: UIKeyboardHIDUsage) -> UInt16 {
        hidToMacKeyCodeMap[hidCode] ?? UInt16(hidCode.rawValue)
    }
}

public extension MirageScrollPhase {
    /// Create from UIGestureRecognizer.State.
    init(gestureState: UIGestureRecognizer.State) {
        switch gestureState {
        case .began: self = .began
        case .changed: self = .changed
        case .ended: self = .ended
        case .cancelled,
             .failed: self = .cancelled
        case .possible: self = .mayBegin
        @unknown default: self = .none
        }
    }
}
#endif
