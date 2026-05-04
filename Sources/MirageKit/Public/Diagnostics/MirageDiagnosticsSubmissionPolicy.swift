//
//  MirageDiagnosticsSubmissionPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/26/26.
//

import Foundation
import Loom

public enum MirageDiagnosticsSentryDisposition: String, Sendable, Equatable {
    case capture
    case breadcrumbOnly
}

public struct MirageDiagnosticsEventClassification: Sendable, Equatable {
    public let disposition: MirageDiagnosticsSentryDisposition
    public let issueKind: String
    public let failureStage: String
    public let recoveryOutcome: String
    public let fallbackUsed: String
    public let transportHealth: String
    public let suppressionKey: String?

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

public enum MirageDiagnosticsSubmissionPolicy {
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

        if lowercasedMessage.contains("target is not foreground") ||
            lowercasedMessage.contains("not foreground") && lowercasedMessage.contains("live activity") {
            return breadcrumbOnly(
                issueKind: "live-activity-foreground",
                failureStage: "activity-request",
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

public struct MirageDiagnosticsSuppressionState: Sendable {
    public static let defaultWindow: TimeInterval = 600
    public static let defaultWindowThreshold = 5
    public static let defaultLaunchThreshold = 10

    private struct Bucket: Sendable {
        var windowStart: TimeInterval
        var windowCount: Int
        var launchCount: Int
    }

    private var buckets: [String: Bucket] = [:]

    public init() {}

    public mutating func shouldEscalate(
        classification: MirageDiagnosticsEventClassification,
        at date: Date,
        window: TimeInterval = Self.defaultWindow,
        windowThreshold: Int = Self.defaultWindowThreshold,
        launchThreshold: Int = Self.defaultLaunchThreshold
    ) -> Bool {
        guard classification.disposition == .breadcrumbOnly,
              let suppressionKey = classification.suppressionKey else {
            return false
        }

        let now = date.timeIntervalSinceReferenceDate
        var bucket = buckets[suppressionKey] ?? Bucket(
            windowStart: now,
            windowCount: 0,
            launchCount: 0
        )

        if now - bucket.windowStart > window {
            bucket.windowStart = now
            bucket.windowCount = 0
        }

        bucket.windowCount += 1
        bucket.launchCount += 1
        buckets[suppressionKey] = bucket

        return bucket.windowCount == windowThreshold ||
            bucket.launchCount == launchThreshold ||
            (bucket.windowCount > windowThreshold && bucket.windowCount.isMultiple(of: windowThreshold)) ||
            (bucket.launchCount > launchThreshold && bucket.launchCount.isMultiple(of: launchThreshold))
    }
}

private extension MirageDiagnosticsSubmissionPolicy {
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

    static func isExpectedCancellation(
        _ event: LoomDiagnosticsErrorEvent,
        lowercasedMessage: String
    ) -> Bool {
        if lowercasedMessage.contains("cancellationerror") {
            return true
        }

        guard let metadata = event.metadata else { return false }
        return metadata.domain == "Swift.CancellationError" ||
            metadata.typeName == "Swift.CancellationError"
    }

    static func isDuplicateStartupReporter(
        _ event: LoomDiagnosticsErrorEvent,
        lowercasedMessage: String
    ) -> Bool {
        guard event.category.rawValue == "appState" || event.category.rawValue == "appstate" else {
            return false
        }

        return lowercasedMessage.contains("client error:") &&
            (
                lowercasedMessage.contains("desktop stream failed") ||
                    lowercasedMessage.contains("desktop stream start timed out") ||
                    lowercasedMessage.contains("stream failed to present its first frame after bounded recovery")
            )
    }

    static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    static func inferredTransportHealth(from lowercasedMessage: String) -> String {
        if lowercasedMessage.contains("no screen samples") ||
            lowercasedMessage.contains("no startup packets") ||
            lowercasedMessage.contains("packet-starved") {
            return "packet-starved"
        }

        if lowercasedMessage.contains("disconnected") ||
            lowercasedMessage.contains("connection") ||
            lowercasedMessage.contains("transport") {
            return "disconnected"
        }

        return "unknown"
    }

    static func normalizedIssueKind(for event: LoomDiagnosticsErrorEvent) -> String {
        if let metadata = event.metadata {
            if metadata.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
                return "screencapturekit"
            }
            if metadata.domain == NSOSStatusErrorDomain {
                return "osstatus"
            }
            if metadata.domain == "MirageKit.MirageError" {
                return "mirage-error"
            }
            if metadata.domain == "Loom.LoomError" {
                return "loom-error"
            }
        }

        return event.category.rawValue
    }

    static func isExpectedTransportSendFailure(
        _ event: LoomDiagnosticsErrorEvent,
        lowercasedMessage: String
    ) -> Bool {
        guard lowercasedMessage.contains("failed to send input") ||
            lowercasedMessage.contains("failed to send session state") ||
            lowercasedMessage.contains("audio transport send failed") ||
            lowercasedMessage.contains("failed reopening audio transport") ||
            lowercasedMessage.contains("control channel closed") else {
            return false
        }

        if lowercasedMessage.contains("unreliable send queue cancelled") ||
            lowercasedMessage.contains("connectionfailed") ||
            lowercasedMessage.contains("cancelled") ||
            lowercasedMessage.contains("closed") {
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

    static func isExpectedWakeFailure(
        _ event: LoomDiagnosticsErrorEvent,
        lowercasedMessage: String
    ) -> Bool {
        guard event.category.rawValue == "wol" ||
            event.category.rawValue == "bootstrapHandoff" ||
            event.category.rawValue == "bootstrap_handoff" else {
            return false
        }

        if lowercasedMessage.contains("wake timed out") {
            return true
        }

        guard lowercasedMessage.contains("wake-on-lan failed") else { return false }
        if lowercasedMessage.contains("permission denied") ||
            lowercasedMessage.contains("sendfailed") ||
            lowercasedMessage.contains("network is unreachable") ||
            lowercasedMessage.contains("cannot assign requested address") {
            return true
        }
        return false
    }

    static func isVirtualDisplayStartupFailure(
        _ event: LoomDiagnosticsErrorEvent,
        lowercasedMessage: String
    ) -> Bool {
        if let metadata = event.metadata,
           metadata.domain.contains("SharedVirtualDisplayManager.SharedDisplayError") {
            return true
        }

        return lowercasedMessage.contains("virtual display acquisition failed") ||
            lowercasedMessage.contains("failed to handle desktop stream request")
    }

    static func isExpectedVersionOrProtocolRejection(_ lowercasedMessage: String) -> Bool {
        lowercasedMessage.contains("protocolversionmismatch") ||
            lowercasedMessage.contains("protocolfeaturesmismatch") ||
            lowercasedMessage.contains("versions are incompatible") ||
            lowercasedMessage.contains("protocol features are incompatible") ||
            lowercasedMessage.contains("incompatible mirage handshake") ||
            lowercasedMessage.contains("invalid mirage bootstrap frame") ||
            lowercasedMessage.contains("malformedbootstrap")
    }
}
