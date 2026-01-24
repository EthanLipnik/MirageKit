//
//  MirageInputEvent.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import CoreGraphics

/// Represents any input event to forward from client to host
public enum MirageInputEvent: Codable, Sendable {
    case keyDown(MirageKeyEvent)
    case keyUp(MirageKeyEvent)
    case flagsChanged(MirageModifierFlags)
    case mouseDown(MirageMouseEvent)
    case mouseUp(MirageMouseEvent)
    case mouseMoved(MirageMouseEvent)
    case mouseDragged(MirageMouseEvent)
    case rightMouseDown(MirageMouseEvent)
    case rightMouseUp(MirageMouseEvent)
    case rightMouseDragged(MirageMouseEvent)
    case otherMouseDown(MirageMouseEvent)
    case otherMouseUp(MirageMouseEvent)
    case otherMouseDragged(MirageMouseEvent)
    case scrollWheel(MirageScrollEvent)
    case magnify(MirageMagnifyEvent)
    case rotate(MirageRotateEvent)
    case windowResize(MirageResizeEvent)
    case relativeResize(MirageRelativeResizeEvent)
    case pixelResize(MiragePixelResizeEvent)

    /// Client window received focus - host should activate the corresponding window
    case windowFocus

    /// Timestamp when the event was created (for latency measurement)
    public var timestamp: TimeInterval {
        switch self {
        case .keyDown(let e), .keyUp(let e): return e.timestamp
        case .flagsChanged, .windowFocus: return Date.timeIntervalSinceReferenceDate
        case .mouseDown(let e), .mouseUp(let e), .mouseMoved(let e), .mouseDragged(let e),
             .rightMouseDown(let e), .rightMouseUp(let e), .rightMouseDragged(let e),
             .otherMouseDown(let e), .otherMouseUp(let e), .otherMouseDragged(let e):
            return e.timestamp
        case .scrollWheel(let e): return e.timestamp
        case .magnify(let e): return e.timestamp
        case .rotate(let e): return e.timestamp
        case .windowResize(let e): return e.timestamp
        case .relativeResize(let e): return e.timestamp
        case .pixelResize(let e): return e.timestamp
        }
    }

    /// Mouse location for events that have cursor position (normalized 0-1)
    /// Used to track last cursor position for graceful input release during decode errors
    public var mouseLocation: CGPoint? {
        switch self {
        case .mouseDown(let e), .mouseUp(let e), .mouseMoved(let e), .mouseDragged(let e),
             .rightMouseDown(let e), .rightMouseUp(let e), .rightMouseDragged(let e),
             .otherMouseDown(let e), .otherMouseUp(let e), .otherMouseDragged(let e):
            return e.location
        case .scrollWheel(let e):
            return e.location
        case .keyDown, .keyUp, .flagsChanged, .windowFocus, .magnify, .rotate,
             .windowResize, .relativeResize, .pixelResize:
            return nil
        }
    }
}

/// Modifier flags for keyboard events
public struct MirageModifierFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let capsLock = MirageModifierFlags(rawValue: 1 << 0)
    public static let shift = MirageModifierFlags(rawValue: 1 << 1)
    public static let control = MirageModifierFlags(rawValue: 1 << 2)
    public static let option = MirageModifierFlags(rawValue: 1 << 3)
    public static let command = MirageModifierFlags(rawValue: 1 << 4)
    public static let numericPad = MirageModifierFlags(rawValue: 1 << 5)
    public static let function = MirageModifierFlags(rawValue: 1 << 6)
}

/// Mouse button enumeration
public enum MirageMouseButton: Int, Codable, Sendable {
    case left = 0
    case right = 1
    case middle = 2
    case button3 = 3
    case button4 = 4

    public init(buttonNumber: Int) {
        switch buttonNumber {
        case 0: self = .left
        case 1: self = .right
        case 2: self = .middle
        case 3: self = .button3
        default: self = .button4
        }
    }
}

/// Scroll phase for trackpad gestures
public enum MirageScrollPhase: Int, Codable, Sendable {
    case none = 0
    case began = 1
    case changed = 2
    case ended = 3
    case cancelled = 4
    case mayBegin = 5
}

// MARK: - macOS CGEvent Conversion Extensions

#if os(macOS)
import AppKit
import Carbon.HIToolbox

extension MirageMouseButton {
    /// Convert to CGMouseButton for CGEvent creation
    public var cgMouseButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle, .button3, .button4: return .center
        }
    }
}

extension MirageModifierFlags {
    /// Convert to CGEventFlags for CGEvent creation
    public var cgEventFlags: CGEventFlags {
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

    /// Create from NSEvent modifier flags
    public init(nsEventFlags: NSEvent.ModifierFlags) {
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

extension MirageScrollPhase {
    /// Create from NSEvent.Phase for scroll wheel events
    public init(from nsPhase: NSEvent.Phase) {
        switch nsPhase {
        case .began: self = .began
        case .changed: self = .changed
        case .stationary: self = .changed  // Stationary still means active scrolling
        case .ended: self = .ended
        case .cancelled: self = .cancelled
        case .mayBegin: self = .mayBegin
        default: self = .none
        }
    }
}
#endif

// MARK: - iOS/iPadOS UIKit Conversion Extensions

#if os(iOS)
import UIKit

extension MirageModifierFlags {
    /// Create from UIKeyModifierFlags (external keyboard)
    public init(uiKeyModifierFlags: UIKeyModifierFlags) {
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

extension MirageKeyEvent {
    /// Create from UIPress (external keyboard)
    public init?(press: UIPress, isRepeat: Bool = false) {
        guard let key = press.key else { return nil }

        // Convert iOS HID usage code to macOS virtual key code
        let macKeyCode = Self.hidToMacKeyCode(key.keyCode)

        self.init(
            keyCode: macKeyCode,
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: MirageModifierFlags(uiKeyModifierFlags: key.modifierFlags),
            isRepeat: isRepeat
        )
    }

    /// Create from UIPress with explicit modifiers (for accurate modifier tracking)
    /// iOS UIPress.key.modifierFlags only reflects modifiers from the same press event,
    /// not modifiers held from previous key presses. Use this initializer with tracked
    /// modifier state for correct behavior.
    public init?(press: UIPress, modifiers: MirageModifierFlags, isRepeat: Bool = false) {
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

    /// Convert iOS HID usage code to macOS virtual key code
    private static func hidToMacKeyCode(_ hidCode: UIKeyboardHIDUsage) -> UInt16 {
        // Map from USB HID Keyboard Usage Page (0x07) to macOS virtual key codes
        switch hidCode {
        // Letters A-Z
        case .keyboardA: return 0x00
        case .keyboardB: return 0x0B
        case .keyboardC: return 0x08
        case .keyboardD: return 0x02
        case .keyboardE: return 0x0E
        case .keyboardF: return 0x03
        case .keyboardG: return 0x05
        case .keyboardH: return 0x04
        case .keyboardI: return 0x22
        case .keyboardJ: return 0x26
        case .keyboardK: return 0x28
        case .keyboardL: return 0x25
        case .keyboardM: return 0x2E
        case .keyboardN: return 0x2D
        case .keyboardO: return 0x1F
        case .keyboardP: return 0x23
        case .keyboardQ: return 0x0C
        case .keyboardR: return 0x0F
        case .keyboardS: return 0x01
        case .keyboardT: return 0x11
        case .keyboardU: return 0x20
        case .keyboardV: return 0x09
        case .keyboardW: return 0x0D
        case .keyboardX: return 0x07
        case .keyboardY: return 0x10
        case .keyboardZ: return 0x06

        // Numbers 1-0
        case .keyboard1: return 0x12
        case .keyboard2: return 0x13
        case .keyboard3: return 0x14
        case .keyboard4: return 0x15
        case .keyboard5: return 0x17
        case .keyboard6: return 0x16
        case .keyboard7: return 0x1A
        case .keyboard8: return 0x1C
        case .keyboard9: return 0x19
        case .keyboard0: return 0x1D

        // Control keys
        case .keyboardReturnOrEnter: return 0x24
        case .keyboardEscape: return 0x35
        case .keyboardDeleteOrBackspace: return 0x33
        case .keyboardTab: return 0x30
        case .keyboardSpacebar: return 0x31
        case .keyboardCapsLock: return 0x39

        // Punctuation
        case .keyboardHyphen: return 0x1B          // -
        case .keyboardEqualSign: return 0x18       // =
        case .keyboardOpenBracket: return 0x21     // [
        case .keyboardCloseBracket: return 0x1E    // ]
        case .keyboardBackslash: return 0x2A       // \
        case .keyboardSemicolon: return 0x29       // ;
        case .keyboardQuote: return 0x27           // '
        case .keyboardGraveAccentAndTilde: return 0x32  // `
        case .keyboardComma: return 0x2B           // ,
        case .keyboardPeriod: return 0x2F          // .
        case .keyboardSlash: return 0x2C           // /

        // Function keys
        case .keyboardF1: return 0x7A
        case .keyboardF2: return 0x78
        case .keyboardF3: return 0x63
        case .keyboardF4: return 0x76
        case .keyboardF5: return 0x60
        case .keyboardF6: return 0x61
        case .keyboardF7: return 0x62
        case .keyboardF8: return 0x64
        case .keyboardF9: return 0x65
        case .keyboardF10: return 0x6D
        case .keyboardF11: return 0x67
        case .keyboardF12: return 0x6F

        // Navigation
        case .keyboardDeleteForward: return 0x75
        case .keyboardHome: return 0x73
        case .keyboardEnd: return 0x77
        case .keyboardPageUp: return 0x74
        case .keyboardPageDown: return 0x79

        // Arrow keys
        case .keyboardRightArrow: return 0x7C
        case .keyboardLeftArrow: return 0x7B
        case .keyboardDownArrow: return 0x7D
        case .keyboardUpArrow: return 0x7E

        // Modifiers (usually handled separately, but include for completeness)
        case .keyboardLeftControl: return 0x3B
        case .keyboardLeftShift: return 0x38
        case .keyboardLeftAlt: return 0x3A         // Option
        case .keyboardLeftGUI: return 0x37         // Command
        case .keyboardRightControl: return 0x3E
        case .keyboardRightShift: return 0x3C
        case .keyboardRightAlt: return 0x3D        // Right Option
        case .keyboardRightGUI: return 0x36        // Right Command

        // Keypad
        case .keypadNumLock: return 0x47
        case .keypadSlash: return 0x4B
        case .keypadAsterisk: return 0x43
        case .keypadHyphen: return 0x4E
        case .keypadPlus: return 0x45
        case .keypadEnter: return 0x4C
        case .keypad1: return 0x53
        case .keypad2: return 0x54
        case .keypad3: return 0x55
        case .keypad4: return 0x56
        case .keypad5: return 0x57
        case .keypad6: return 0x58
        case .keypad7: return 0x59
        case .keypad8: return 0x5B
        case .keypad9: return 0x5C
        case .keypad0: return 0x52
        case .keypadPeriod: return 0x41
        case .keypadEqualSign: return 0x51

        default:
            // For unmapped keys, return raw value (may not work correctly)
            return UInt16(hidCode.rawValue)
        }
    }
}

extension MirageScrollPhase {
    /// Create from UIGestureRecognizer.State
    public init(gestureState: UIGestureRecognizer.State) {
        switch gestureState {
        case .began: self = .began
        case .changed: self = .changed
        case .ended: self = .ended
        case .cancelled, .failed: self = .cancelled
        case .possible: self = .mayBegin
        @unknown default: self = .none
        }
    }
}
#endif
