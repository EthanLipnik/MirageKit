//
//  HostKeyboardInputDiagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//
//  Rate-limited desktop keyboard input diagnostics.
//

import Foundation
import MirageKit

#if os(macOS)
import ApplicationServices

enum HostKeyboardInputDiagnostics {
    private static let rateLimiter = MirageKeyboardInputDiagnosticRateLimiter()

    static func logReceive(
        event: MirageInputEvent,
        streamID: StreamID,
        sessionActive: Bool,
        path: String
    ) {
        guard let diagnostic = MirageKeyboardInputDiagnostics.diagnosticEvent(for: event) else { return }
        log(
            phase: "receive",
            diagnostic: diagnostic,
            streamID: streamID,
            path: path,
            details: "activeSession=\(sessionActive)"
        )
    }

    static func logTargetResolution(
        event: MirageInputEvent,
        streamID: StreamID,
        targetState: String,
        path: String
    ) {
        guard let diagnostic = MirageKeyboardInputDiagnostics.diagnosticEvent(for: event) else { return }
        log(
            phase: "target",
            diagnostic: diagnostic,
            streamID: streamID,
            path: path,
            details: "target=\(targetState)"
        )
    }

    static func logPost(
        keyEvent: MirageKeyEvent,
        isKeyDown: Bool,
        domain: HostKeyboardInjectionDomain
    ) {
        let diagnostic = MirageKeyboardInputDiagnosticEvent(
            kind: isKeyDown ? (keyEvent.isRepeat ? "key_down_repeat" : "key_down") : "key_up",
            keyCodeCategory: MirageKeyboardInputDiagnostics.keyCodeCategory(keyEvent.keyCode),
            isRepeat: keyEvent.isRepeat
        )
        logPost(diagnostic: diagnostic, domain: domain)
    }

    static func logPost(
        modifiers: MirageModifierFlags,
        domain: HostKeyboardInjectionDomain
    ) {
        let diagnostic = MirageKeyboardInputDiagnosticEvent(
            kind: "flags_changed",
            keyCodeCategory: modifiers.isEmpty ? "modifier_state_empty" : "modifier_state_nonempty",
            isRepeat: false
        )
        logPost(diagnostic: diagnostic, domain: domain)
    }

    private static func logPost(
        diagnostic: MirageKeyboardInputDiagnosticEvent,
        domain: HostKeyboardInjectionDomain
    ) {
        log(
            phase: "post",
            diagnostic: diagnostic,
            streamID: nil,
            path: "host_post",
            details: "domain=\(domain.logLabel), accessibilityTrusted=\(AXIsProcessTrusted())"
        )
    }

    private static func log(
        phase: String,
        diagnostic: MirageKeyboardInputDiagnosticEvent,
        streamID: StreamID?,
        path: String,
        details: String
    ) {
        let streamText = streamID.map(String.init) ?? "unknown"
        let rateLimitKey = "host:\(phase):\(streamText):\(path):\(diagnostic.rateLimitKey)"
        guard rateLimiter.shouldLog(key: rateLimitKey) else { return }
        MirageLogger.host(
            "Keyboard input \(phase): stream=\(streamText), kind=\(diagnostic.kind), " +
                "key=\(diagnostic.keyCodeCategory), path=\(path), \(details)"
        )
    }
}

private extension HostKeyboardInjectionDomain {
    var logLabel: String {
        switch self {
        case .hid:
            "hid"
        case .session:
            "session"
        }
    }
}
#endif
