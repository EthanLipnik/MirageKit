//
//  MirageDiagnosticsModels.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Mirage-owned severity for diagnostics error events.
public enum MirageDiagnosticsErrorSeverity: String, Sendable, Codable, Equatable {
    /// Reportable error-level diagnostics.
    case error
    /// Fault-level diagnostics emitted outside the ordinary error path.
    case fault
}

/// Mirage-owned projection of diagnostics error metadata.
public struct MirageDiagnosticsErrorMetadata: Sendable, Codable, Equatable {
    /// Runtime type name associated with the original error.
    public let typeName: String
    /// Low-level domain associated with the original error.
    public let domain: String
    /// Low-level error code associated with the original error.
    public let code: Int

    /// Creates a diagnostics metadata projection.
    public init(typeName: String, domain: String, code: Int) {
        self.typeName = typeName
        self.domain = domain
        self.code = code
    }

    /// Creates a diagnostics metadata projection from an error value.
    public init(error: Error) {
        let nsError = error as NSError
        self.init(
            typeName: String(reflecting: type(of: error)),
            domain: nsError.domain,
            code: nsError.code
        )
    }
}

/// Mirage-owned projection of a diagnostics error event.
public struct MirageDiagnosticsErrorEventSnapshot: Sendable, Codable, Equatable {
    /// Low-cardinality diagnostics category name.
    public let category: String
    /// Event severity.
    public let severity: MirageDiagnosticsErrorSeverity
    /// Human-readable event message.
    public let message: String
    /// Optional error metadata.
    public let metadata: MirageDiagnosticsErrorMetadata?

    /// Creates a diagnostics event projection.
    public init(
        category: String,
        severity: MirageDiagnosticsErrorSeverity,
        message: String,
        metadata: MirageDiagnosticsErrorMetadata? = nil
    ) {
        self.category = category
        self.severity = severity
        self.message = message
        self.metadata = metadata
    }
}

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

/// Tracks repeated breadcrumb-only events and escalates noisy patterns to captures.
public struct MirageDiagnosticsSuppressionState: Sendable {
    /// Default rolling window used for repeated-event suppression.
    public static let defaultWindow: TimeInterval = 600
    /// Default number of events in the rolling window before escalation.
    public static let defaultWindowThreshold = 5
    /// Default number of events during one launch before escalation.
    public static let defaultLaunchThreshold = 10

    private struct Bucket {
        var windowStart: TimeInterval
        var windowCount: Int
        var launchCount: Int
    }

    private var buckets: [String: Bucket] = [:]

    /// Creates an empty suppression tracker.
    public init() {}

    /// Returns whether a breadcrumb-only classification should be captured after repeated occurrences.
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
