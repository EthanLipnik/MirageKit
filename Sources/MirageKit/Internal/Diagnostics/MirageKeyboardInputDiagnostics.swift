//
//  MirageKeyboardInputDiagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//
//  Redacted keyboard input diagnostics shared by client and host targets.
//

import Foundation

package struct MirageKeyboardInputDiagnosticEvent: Sendable, Equatable {
    package let kind: String
    package let keyCodeCategory: String
    package let isRepeat: Bool

    package init(kind: String, keyCodeCategory: String, isRepeat: Bool) {
        self.kind = kind
        self.keyCodeCategory = keyCodeCategory
        self.isRepeat = isRepeat
    }

    package var rateLimitKey: String {
        "\(kind):\(keyCodeCategory)"
    }
}

package enum MirageKeyboardInputDiagnostics {
    package static func diagnosticEvent(for event: MirageInputEvent) -> MirageKeyboardInputDiagnosticEvent? {
        switch event {
        case let .keyDown(keyEvent):
            MirageKeyboardInputDiagnosticEvent(
                kind: keyEvent.isRepeat ? "key_down_repeat" : "key_down",
                keyCodeCategory: keyCodeCategory(keyEvent.keyCode),
                isRepeat: keyEvent.isRepeat
            )
        case let .keyUp(keyEvent):
            MirageKeyboardInputDiagnosticEvent(
                kind: "key_up",
                keyCodeCategory: keyCodeCategory(keyEvent.keyCode),
                isRepeat: keyEvent.isRepeat
            )
        case .flagsChanged:
            MirageKeyboardInputDiagnosticEvent(
                kind: "flags_changed",
                keyCodeCategory: "modifier_state",
                isRepeat: false
            )
        default:
            nil
        }
    }

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

package final class MirageKeyboardInputDiagnosticRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: CFTimeInterval
    private var lastLogByKey: [String: CFAbsoluteTime] = [:]

    package init(interval: CFTimeInterval = 2.0) {
        self.interval = interval
    }

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
