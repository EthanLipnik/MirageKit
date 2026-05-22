//
//  MirageDiagnosticsSubmissionPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/26/26.
//

import Foundation
import Loom

/// Sentry handling decision for a classified Mirage diagnostics event.
public enum MirageDiagnosticsSentryDisposition: String, Sendable, Equatable {
    /// Submit the event as a reportable Sentry issue.
    case capture
    /// Keep the event as breadcrumb context unless suppression thresholds are exceeded.
    case breadcrumbOnly
}

/// Normalized telemetry classification attached to Mirage diagnostics events.
public struct MirageDiagnosticsEventClassification: Sendable, Equatable {
    /// Whether Sentry should capture the event or retain it as breadcrumb-only context.
    public let disposition: MirageDiagnosticsSentryDisposition
    /// Stable low-cardinality issue identifier.
    public let issueKind: String
    /// Pipeline or lifecycle stage where the failure occurred.
    public let failureStage: String
    /// Recovery result associated with the event.
    public let recoveryOutcome: String
    /// Fallback path used before the event was emitted.
    public let fallbackUsed: String
    /// Transport condition inferred from diagnostics text or context.
    public let transportHealth: String
    /// Optional key used to group repeated breadcrumb-only events for escalation.
    public let suppressionKey: String?

    /// Creates a normalized diagnostics classification and optional suppression group.
    public init(
        disposition: MirageDiagnosticsSentryDisposition,
        issueKind: String,
        failureStage: String,
        recoveryOutcome: String,
        fallbackUsed: String = "none",
        transportHealth: String = "unknown",
        suppressionKey: String? = nil
    ) {
        self.disposition = disposition
        self.issueKind = issueKind
        self.failureStage = failureStage
        self.recoveryOutcome = recoveryOutcome
        self.fallbackUsed = fallbackUsed
        self.transportHealth = transportHealth
        self.suppressionKey = suppressionKey
    }

    /// Tags applied to captured Sentry events.
    public var sentryTags: [String: String] {
        [
            "mirage_issue_kind": issueKind,
            "mirage_failure_stage": failureStage,
            "mirage_recovery_outcome": recoveryOutcome,
            "mirage_fallback_used": fallbackUsed,
            "mirage_transport_health": transportHealth,
        ]
    }
}

/// Classifies diagnostics events before telemetry submission.
public enum MirageDiagnosticsSubmissionPolicy {
    /// Returns the submission classification tags for a diagnostics error event.
    public static func classification(for event: LoomDiagnosticsErrorEvent) -> MirageDiagnosticsEventClassification {
        guard event.severity == .error else {
            return capture(
                issueKind: "fault",
                failureStage: event.category.rawValue,
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
                failureStage: event.category.rawValue,
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
            failureStage: event.category.rawValue,
            recoveryOutcome: "unrecovered"
        )
    }
}
