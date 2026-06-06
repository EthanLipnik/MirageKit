//
//  MirageDiagnosticsSubmissionPolicy.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Classifies Mirage diagnostics events before telemetry submission.
public enum MirageDiagnosticsSubmissionPolicy {
    /// Stable user-visible substring emitted when bounded first-frame recovery is exhausted.
    public static let firstFramePresentationFailureTerminalMessage =
        "Stream failed to present its first frame after bounded recovery."

    /// Returns whether a user-visible error or disconnect reason represents terminal first-frame failure.
    public static func isFirstFramePresentationTerminalFailure(_ message: String) -> Bool {
        message.contains(firstFramePresentationFailureTerminalMessage)
    }

    /// Returns the submission classification tags for a diagnostics error event.
    public static func classification(
        for event: MirageDiagnosticsErrorEventSnapshot
    ) -> MirageDiagnosticsEventClassification {
        guard event.severity == .error else {
            return capture(
                issueKind: "fault",
                failureStage: event.category,
                recoveryOutcome: "unrecovered"
            )
        }

        let message = event.message
        let lowercasedMessage = message.lowercased()

        if isExpectedCancellation(event, lowercasedMessage: lowercasedMessage) {
            return breadcrumbOnly(
                issueKind: "expected-disconnect",
                failureStage: "lifecycle",
                recoveryOutcome: "expected-lifecycle"
            )
        }

        if containsAny(
            lowercasedMessage,
            [
                "desktop stream client disconnected during startup",
                "client closed during desktop startup",
                "local stop during startup",
                "desktop stream setup cancelled by client",
                "authenticated loom session closed before mirage control stream opened",
                "control stream closed before session bootstrap request",
                "control stream closed before receiving a mirage control message",
                "loom session closed",
            ]
        ) {
            return breadcrumbOnly(
                issueKind: "expected-disconnect",
                failureStage: "startup",
                recoveryOutcome: "expected-lifecycle"
            )
        }

        if isExpectedTransportSendFailure(event, lowercasedMessage: lowercasedMessage) {
            return breadcrumbOnly(
                issueKind: "expected-transport-close",
                failureStage: event.category,
                recoveryOutcome: "expected-lifecycle"
            )
        }

        if isExpectedWakeFailure(event, lowercasedMessage: lowercasedMessage) {
            return breadcrumbOnly(
                issueKind: "wake-unavailable",
                failureStage: "wake",
                recoveryOutcome: "expected-environment"
            )
        }

        if isExpectedBootstrapHandoffConnectionRace(event, lowercasedMessage: lowercasedMessage) {
            return breadcrumbOnly(
                issueKind: "bootstrap-handoff-already-connected",
                failureStage: "bootstrap-handoff",
                recoveryOutcome: "expected-lifecycle"
            )
        }

        if lowercasedMessage.contains("max app windows reached") {
            return breadcrumbOnly(
                issueKind: "app-window-capacity",
                failureStage: "app-selection",
                recoveryOutcome: "expected-limit"
            )
        }

        if isExpectedVersionOrProtocolRejection(lowercasedMessage) {
            return breadcrumbOnly(
                issueKind: "protocol-incompatible",
                failureStage: "bootstrap",
                recoveryOutcome: "expected-version-gate"
            )
        }

        if lowercasedMessage.contains("software update check watchdog timed out") &&
            lowercasedMessage.contains("clearing stuck checking state") {
            return breadcrumbOnly(
                issueKind: "software-update-watchdog",
                failureStage: "software-update-check",
                recoveryOutcome: "recovered"
            )
        }

        if isDuplicateStartupReporter(event, lowercasedMessage: lowercasedMessage) {
            return breadcrumbOnly(
                issueKind: "duplicate-startup-failure",
                failureStage: "startup",
                recoveryOutcome: "duplicate"
            )
        }

        if lowercasedMessage.contains("desktop stream start timed out") {
            return capture(
                issueKind: "desktop-startup-failure",
                failureStage: "startup",
                recoveryOutcome: "fallback-exhausted",
                transportHealth: inferredTransportHealth(from: lowercasedMessage)
            )
        }

        if lowercasedMessage.contains("failed to restart desktop virtual display after display topology change") {
            return breadcrumbOnly(
                issueKind: "desktop-topology-refresh",
                failureStage: "display-topology",
                recoveryOutcome: "expected-lifecycle"
            )
        }

        if isScreenCaptureKitContentListUnavailable(event) {
            return capture(
                issueKind: "screencapturekit-content-list-unavailable",
                failureStage: "capture-start",
                recoveryOutcome: "fallback-exhausted"
            )
        }

        if isVirtualDisplayStartupFailure(event, lowercasedMessage: lowercasedMessage) {
            return capture(
                issueKind: "virtual-display-startup",
                failureStage: "startup",
                recoveryOutcome: "fallback-exhausted"
            )
        }

        if lowercasedMessage.contains("startup recovery exhausted") {
            return capture(
                issueKind: "startup-first-frame-timeout",
                failureStage: "first-frame",
                recoveryOutcome: "fallback-exhausted",
                transportHealth: lowercasedMessage.contains("packet") ? "packet-starved" : "unknown"
            )
        }

        if lowercasedMessage.contains("terminal startup failure") {
            return breadcrumbOnly(
                issueKind: "duplicate-startup-failure",
                failureStage: "first-frame",
                recoveryOutcome: "duplicate"
            )
        }

        if lowercasedMessage.contains("retrying without audio") {
            return breadcrumbOnly(
                issueKind: "screencapturekit-audio-start",
                failureStage: "capture-start",
                recoveryOutcome: "fallback-in-progress",
                fallbackUsed: "audio-disabled-retry"
            )
        }

        if lowercasedMessage.contains("display current space restore remained incomplete") {
            return breadcrumbOnly(
                issueKind: "display-space-restore",
                failureStage: "display-restore",
                recoveryOutcome: "verification-incomplete"
            )
        }

        if lowercasedMessage.contains("desktop stream start failed") ||
            lowercasedMessage.contains("desktop stream failed") {
            return capture(
                issueKind: "desktop-startup-failure",
                failureStage: "startup",
                recoveryOutcome: "fallback-exhausted",
                transportHealth: inferredTransportHealth(from: lowercasedMessage)
            )
        }

        return capture(
            issueKind: normalizedIssueKind(for: event),
            failureStage: event.category,
            recoveryOutcome: "unrecovered"
        )
    }
}

extension MirageDiagnosticsSubmissionPolicy {
    /// Builds a reportable diagnostics classification.
    static func capture(
        issueKind: String,
        failureStage: String,
        recoveryOutcome: String,
        fallbackUsed: String = "none",
        transportHealth: String = "unknown"
    ) -> MirageDiagnosticsEventClassification {
        MirageDiagnosticsEventClassification(
            disposition: .capture,
            issueKind: issueKind,
            failureStage: failureStage,
            recoveryOutcome: recoveryOutcome,
            fallbackUsed: fallbackUsed,
            transportHealth: transportHealth,
            suppressionKey: nil
        )
    }

    /// Builds a breadcrumb-only classification, optionally with a repeated-event suppression key.
    static func breadcrumbOnly(
        issueKind: String,
        failureStage: String,
        recoveryOutcome: String,
        fallbackUsed: String = "none",
        transportHealth: String = "unknown",
        allowEscalation: Bool = false
    ) -> MirageDiagnosticsEventClassification {
        MirageDiagnosticsEventClassification(
            disposition: .breadcrumbOnly,
            issueKind: issueKind,
            failureStage: failureStage,
            recoveryOutcome: recoveryOutcome,
            fallbackUsed: fallbackUsed,
            transportHealth: transportHealth,
            suppressionKey: allowEscalation
                ? "\(issueKind):\(failureStage):\(recoveryOutcome):\(fallbackUsed):\(transportHealth)"
                : nil
        )
    }

    /// Returns whether the event represents an expected Swift cancellation.
    static func isExpectedCancellation(
        _ event: MirageDiagnosticsErrorEventSnapshot,
        lowercasedMessage: String
    ) -> Bool {
        if lowercasedMessage.contains("cancellationerror") {
            return true
        }

        guard let metadata = event.metadata else { return false }
        return metadata.domain == "Swift.CancellationError" ||
            metadata.typeName == "Swift.CancellationError"
    }

    /// Returns whether AppState is re-reporting an already classified startup failure.
    static func isDuplicateStartupReporter(
        _ event: MirageDiagnosticsErrorEventSnapshot,
        lowercasedMessage: String
    ) -> Bool {
        guard category(event, matchesAnyOf: ["appState", "appstate"]) else { return false }

        return lowercasedMessage.contains("client error:") &&
            (
                lowercasedMessage.contains("desktop stream failed") ||
                    lowercasedMessage.contains("desktop stream start timed out") ||
                    lowercasedMessage.contains(firstFramePresentationFailureTerminalMessage.lowercased())
            )
    }

    /// Returns true when `value` contains at least one candidate substring.
    static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    /// Infers a coarse transport health tag from diagnostics text.
    static func inferredTransportHealth(from lowercasedMessage: String) -> String {
        if containsAny(lowercasedMessage, ["no screen samples", "no startup packets", "packet-starved"]) {
            return "packet-starved"
        }

        if containsAny(lowercasedMessage, ["disconnected", "connection", "transport"]) {
            return "disconnected"
        }

        return "unknown"
    }

    /// Converts event metadata into a low-cardinality fallback issue kind.
    static func normalizedIssueKind(for event: MirageDiagnosticsErrorEventSnapshot) -> String {
        if let metadata = event.metadata {
            if metadata.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
                return "screencapturekit"
            }
            if metadata.domain == NSOSStatusErrorDomain {
                return "osstatus"
            }
            if metadata.domain == "MirageCore.MirageError" {
                return "mirage-error"
            }
            if metadata.domain == "Loom.LoomError" {
                return "loom-error"
            }
        }

        return event.category
    }

    /// Matches diagnostics category names while preserving their exact emitted spellings.
    static func category(
        _ event: MirageDiagnosticsErrorEventSnapshot,
        matchesAnyOf categoryNames: [String]
    ) -> Bool {
        categoryNames.contains(event.category)
    }

    /// Returns whether a send failure represents a normal remote/control-channel close.
    static func isExpectedTransportSendFailure(
        _ event: MirageDiagnosticsErrorEventSnapshot,
        lowercasedMessage: String
    ) -> Bool {
        guard containsAny(
            lowercasedMessage,
            [
                "failed to send input",
                "failed to send session state",
                "audio transport send failed",
                "failed reopening audio transport",
                "control channel closed",
            ]
        ) else {
            return false
        }

        if containsAny(lowercasedMessage, ["unreliable send queue cancelled", "connectionfailed", "cancelled", "closed"]) {
            return true
        }

        guard let metadata = event.metadata else { return false }
        if metadata.domain == "Loom.LoomError" {
            return metadata.code == 0 || metadata.code == 3
        }
        if metadata.domain == NSPOSIXErrorDomain {
            return [32, 54, 57, 89].contains(metadata.code)
        }
        return false
    }

    /// Returns whether a wake failure is expected for the current network or permission state.
    static func isExpectedWakeFailure(
        _ event: MirageDiagnosticsErrorEventSnapshot,
        lowercasedMessage: String
    ) -> Bool {
        guard category(event, matchesAnyOf: ["wol", "bootstrapHandoff", "bootstrap_handoff"]) else { return false }

        if lowercasedMessage.contains("wake timed out") {
            return true
        }

        guard lowercasedMessage.contains("wake-on-lan failed") else { return false }
        return containsAny(
            lowercasedMessage,
            ["permission denied", "sendfailed", "network is unreachable", "cannot assign requested address"]
        )
    }

    /// Returns whether bootstrap handoff lost a benign race with an existing client connection.
    static func isExpectedBootstrapHandoffConnectionRace(
        _ event: MirageDiagnosticsErrorEventSnapshot,
        lowercasedMessage: String
    ) -> Bool {
        guard category(event, matchesAnyOf: ["bootstrapHandoff", "bootstrap_handoff"]) else { return false }

        return lowercasedMessage.contains("already connected or connecting")
    }

    /// Returns whether ScreenCaptureKit failed to enumerate shareable content.
    static func isScreenCaptureKitContentListUnavailable(_ event: MirageDiagnosticsErrorEventSnapshot) -> Bool {
        guard let metadata = event.metadata,
              metadata.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" else {
            return false
        }
        return [-3813, -3814, -3815].contains(metadata.code)
    }

    /// Returns whether an event describes virtual display startup exhaustion.
    static func isVirtualDisplayStartupFailure(
        _ event: MirageDiagnosticsErrorEventSnapshot,
        lowercasedMessage: String
    ) -> Bool {
        if let metadata = event.metadata,
           metadata.domain.contains("SharedVirtualDisplayManager.SharedDisplayError") {
            return true
        }

        return lowercasedMessage.contains("virtual display acquisition failed") ||
            lowercasedMessage.contains("failed to handle desktop stream request")
    }

    /// Returns whether bootstrap rejected a peer because the wire protocol is incompatible.
    static func isExpectedVersionOrProtocolRejection(_ lowercasedMessage: String) -> Bool {
        containsAny(
            lowercasedMessage,
            [
                "protocolversionmismatch",
                "protocol version is incompatible",
                "versions are incompatible",
                "loom session protocol version is incompatible",
                "incompatible mirage handshake",
                "invalid mirage bootstrap frame",
                "malformedbootstrap",
            ]
        )
    }
}
