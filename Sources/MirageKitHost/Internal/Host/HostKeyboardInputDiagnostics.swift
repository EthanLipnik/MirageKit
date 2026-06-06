//
//  HostKeyboardInputDiagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//
//  Rate-limited desktop keyboard input diagnostics.
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

#if os(macOS)
import ApplicationServices

/// Host-side keyboard diagnostic logger for receive, target-resolution, and injection phases.
enum HostKeyboardInputDiagnostics {
    private static let rateLimiter = MirageKeyboardInputDiagnosticRateLimiter()

    /// Logs that the host received a keyboard input event from the control path.
    static func logReceive(
        event: MirageInput.MirageInputEvent,
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

    /// Logs the stream/window target selected for a keyboard input event.
    static func logTargetResolution(
        event: MirageInput.MirageInputEvent,
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

    /// Logs a posted key event after host injection chooses an input domain.
    static func logPost(
        keyEvent: MirageInput.MirageKeyEvent,
        isKeyDown: Bool,
        domain: HostKeyboardInjectionDomain
    ) {
        let diagnostic = MirageKeyboardInputDiagnosticEvent(
            kind: isKeyDown ? (keyEvent.isRepeat ? "key_down_repeat" : "key_down") : "key_up",
            keyCodeCategory: MirageKeyboardInputDiagnostics.keyCodeCategory(keyEvent.keyCode)
        )
        logPost(diagnostic: diagnostic, domain: domain)
    }

    /// Logs a posted modifier-state event after host injection chooses an input domain.
    static func logPost(
        modifiers: MirageInput.MirageModifierFlags,
        domain: HostKeyboardInjectionDomain
    ) {
        let diagnostic = MirageKeyboardInputDiagnosticEvent(
            kind: "flags_changed",
            keyCodeCategory: modifiers.isEmpty ? "modifier_state_empty" : "modifier_state_nonempty"
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
    /// Stable label used in host keyboard diagnostics.
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
