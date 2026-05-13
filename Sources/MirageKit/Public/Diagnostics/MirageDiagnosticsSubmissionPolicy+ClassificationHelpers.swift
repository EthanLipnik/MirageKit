//
//  MirageDiagnosticsSubmissionPolicy+ClassificationHelpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import Loom

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

    /// Returns whether AppState is re-reporting an already classified startup failure.
    static func isDuplicateStartupReporter(
        _ event: LoomDiagnosticsErrorEvent,
        lowercasedMessage: String
    ) -> Bool {
        guard category(event, matchesAnyOf: ["appState", "appstate"]) else { return false }

        return lowercasedMessage.contains("client error:") &&
            (
                lowercasedMessage.contains("desktop stream failed") ||
                    lowercasedMessage.contains("desktop stream start timed out") ||
                    lowercasedMessage.contains(MirageKit.firstFramePresentationFailureTerminalMessage.lowercased())
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

    /// Matches diagnostics category names while preserving their exact emitted spellings.
    static func category(
        _ event: LoomDiagnosticsErrorEvent,
        matchesAnyOf categoryNames: [String]
    ) -> Bool {
        categoryNames.contains(event.category.rawValue)
    }

    /// Returns whether a send failure represents a normal remote/control-channel close.
    static func isExpectedTransportSendFailure(
        _ event: LoomDiagnosticsErrorEvent,
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
        _ event: LoomDiagnosticsErrorEvent,
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
        _ event: LoomDiagnosticsErrorEvent,
        lowercasedMessage: String
    ) -> Bool {
        guard category(event, matchesAnyOf: ["bootstrapHandoff", "bootstrap_handoff"]) else { return false }

        return lowercasedMessage.contains("already connected or connecting")
    }

    /// Returns whether ScreenCaptureKit failed to enumerate shareable content.
    static func isScreenCaptureKitContentListUnavailable(_ event: LoomDiagnosticsErrorEvent) -> Bool {
        guard let metadata = event.metadata,
              metadata.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" else {
            return false
        }
        return [-3813, -3814, -3815].contains(metadata.code)
    }

    /// Returns whether an event describes virtual display startup exhaustion.
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

    /// Returns whether bootstrap rejected a peer because the wire protocol is incompatible.
    static func isExpectedVersionOrProtocolRejection(_ lowercasedMessage: String) -> Bool {
        containsAny(
            lowercasedMessage,
            [
                "protocolversionmismatch",
                "versions are incompatible",
                "incompatible mirage handshake",
                "invalid mirage bootstrap frame",
                "malformedbootstrap",
            ]
        )
    }
}
