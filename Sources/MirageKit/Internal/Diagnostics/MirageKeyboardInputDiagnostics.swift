//
//  MirageKeyboardInputDiagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//
//  Redacted keyboard input diagnostics shared by client and host targets.
//

import Foundation

/// Redacted keyboard diagnostic payload that never includes typed characters.
package struct MirageKeyboardInputDiagnosticEvent: Sendable, Equatable {
    /// Event category, such as key-down, key-up, repeat, or modifier-state change.
    package let kind: String

    /// Coarse key class used for debugging routing without logging the actual key.
    package let keyCodeCategory: String

    /// Creates a redacted keyboard diagnostic event.
    package init(kind: String, keyCodeCategory: String) {
        self.kind = kind
        self.keyCodeCategory = keyCodeCategory
    }

    /// Stable key used to throttle repeated logs for the same event category.
    package var rateLimitKey: String {
        "\(kind):\(keyCodeCategory)"
    }
}

/// Shared keyboard-input diagnostic classifier for client send paths and host receive/post paths.
package enum MirageKeyboardInputDiagnostics {
    /// Returns a redacted diagnostic event for keyboard input, or nil for non-keyboard input.
    package static func diagnosticEvent(for event: MirageInputEvent) -> MirageKeyboardInputDiagnosticEvent? {
        switch event {
        case let .keyDown(keyEvent):
            MirageKeyboardInputDiagnosticEvent(
                kind: keyEvent.isRepeat ? "key_down_repeat" : "key_down",
                keyCodeCategory: keyCodeCategory(keyEvent.keyCode)
            )
        case let .keyUp(keyEvent):
            MirageKeyboardInputDiagnosticEvent(
                kind: "key_up",
                keyCodeCategory: keyCodeCategory(keyEvent.keyCode)
            )
        case .flagsChanged:
            MirageKeyboardInputDiagnosticEvent(
                kind: "flags_changed",
                keyCodeCategory: "modifier_state"
            )
        default:
            nil
        }
    }

    /// Maps a hardware key code into a coarse category that is safe to log.
    package static func keyCodeCategory(_ keyCode: UInt16) -> String {
        if keyCode == MirageKeyEvent.unicodeScalarFallbackKeyCode {
            return "unicode_fallback"
        }

        switch keyCode {
        case 0x24, 0x30, 0x31, 0x33, 0x35, 0x47, 0x4C:
            return "navigation_or_editing"
        case 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F:
            return "modifier"
        case 0x7B, 0x7C, 0x7D, 0x7E:
            return "arrow"
        case 0x60...0x6F:
            return "function"
        case 0x52...0x5C:
            return "keypad"
        case 0x00...0x32:
            return "layout_key"
        default:
            return "other"
        }
    }
}

/// Small lock-backed rate limiter for repeated keyboard diagnostic messages.
package final class MirageKeyboardInputDiagnosticRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: CFTimeInterval
    private var lastLogByKey: [String: CFAbsoluteTime] = [:]

    /// Creates a rate limiter with the minimum interval between logs for the same key.
    package init(interval: CFTimeInterval = 2.0) {
        self.interval = interval
    }

    /// Returns true when a diagnostic with the supplied key should be emitted now.
    package func shouldLog(key: String, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let lastLog = lastLogByKey[key],
           now - lastLog < interval {
            return false
        }

        lastLogByKey[key] = now
        return true
    }
}
