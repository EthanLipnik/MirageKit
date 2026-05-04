//
//  MirageDiagnosticsSubmissionPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/26/26.
//

@testable import MirageKit
import Foundation
import Loom
import Testing

@Suite("Mirage Diagnostics Submission Policy")
struct MirageDiagnosticsSubmissionPolicyTests {
    @Test("Expected desktop startup disconnects stay breadcrumb-only")
    func expectedDesktopStartupDisconnectsStayBreadcrumbOnly() {
        let classification = MirageDiagnosticsSubmissionPolicy.classification(
            for: makeEvent(
                category: "client",
                message: "Desktop stream start failed: Failed to start desktop stream: Protocol error: Desktop stream client disconnected during startup"
            )
        )

        #expect(classification.disposition == .breadcrumbOnly)
        #expect(classification.issueKind == "expected-disconnect")
    }

    @Test("Local startup stops stay breadcrumb-only")
    func localStartupStopsStayBreadcrumbOnly() {
        let classification = MirageDiagnosticsSubmissionPolicy.classification(
            for: makeEvent(
                category: "host",
                message: "Desktop stream failed: local stop during startup"
            )
        )

        #expect(classification.disposition == .breadcrumbOnly)
        #expect(classification.issueKind == "expected-disconnect")
    }

    @Test("AppState duplicate startup errors stay breadcrumb-only")
    func appStateDuplicateStartupErrorsStayBreadcrumbOnly() {
        let classification = MirageDiagnosticsSubmissionPolicy.classification(
            for: makeEvent(
                category: "appState",
                message: "Client error: protocolError(\"Desktop stream failed: failed waiting for first display sample\")"
            )
        )

        #expect(classification.disposition == .breadcrumbOnly)
        #expect(classification.recoveryOutcome == "duplicate")
    }

    @Test("AppState startup timeout duplicates stay breadcrumb-only")
    func appStateStartupTimeoutDuplicatesStayBreadcrumbOnly() {
        let classification = MirageDiagnosticsSubmissionPolicy.classification(
            for: makeEvent(
                category: "appState",
                message: "Client error: protocolError(\"Desktop stream start timed out. The host may be busy or unreachable.\")"
            )
        )

        #expect(classification.disposition == .breadcrumbOnly)
        #expect(classification.issueKind == "duplicate-startup-failure")
    }

    @Test("Unrecovered startup exhaustion remains reportable")
    func unrecoveredStartupExhaustionRemainsReportable() {
        let classification = MirageDiagnosticsSubmissionPolicy.classification(
            for: makeEvent(
                category: "client",
                message: "Startup recovery exhausted for stream 2 after 1 hard recovery attempt(s) (reason=startup-keyframe-timeout, waitReason=startup-hard-recovery)"
            )
        )

        #expect(classification.disposition == .capture)
        #expect(classification.issueKind == "startup-first-frame-timeout")
        #expect(classification.recoveryOutcome == "fallback-exhausted")
    }

    @Test("Desktop start timeouts are grouped under startup failures")
    func desktopStartTimeoutsAreGroupedUnderStartupFailures() {
        let classification = MirageDiagnosticsSubmissionPolicy.classification(
            for: makeEvent(
                category: "client",
                message: "Desktop stream start timed out after 30s"
            )
        )

        #expect(classification.disposition == .capture)
        #expect(classification.issueKind == "desktop-startup-failure")
        #expect(classification.failureStage == "startup")
    }

    @Test("Virtual display startup errors get a concrete issue kind")
    func virtualDisplayStartupErrorsGetConcreteIssueKind() {
        let classification = MirageDiagnosticsSubmissionPolicy.classification(
            for: makeEvent(
                category: "host",
                message: "Failed to handle desktop stream request: ",
                metadata: LoomDiagnosticsErrorMetadata(
                    typeName: "MirageKitHost.SharedVirtualDisplayManager.SharedDisplayError",
                    domain: "MirageKitHost.SharedVirtualDisplayManager.SharedDisplayError",
                    code: 4
                )
            )
        )

        #expect(classification.disposition == .capture)
        #expect(classification.issueKind == "virtual-display-startup")
    }

    @Test("Expected transport closures stay breadcrumb-only")
    func expectedTransportClosuresStayBreadcrumbOnly() {
        let classification = MirageDiagnosticsSubmissionPolicy.classification(
            for: makeEvent(
                category: "client",
                message: "Failed to send input: ",
                metadata: LoomDiagnosticsErrorMetadata(
                    typeName: "Loom.LoomError",
                    domain: "Loom.LoomError",
                    code: 0
                )
            )
        )

        #expect(classification.disposition == .breadcrumbOnly)
        #expect(classification.issueKind == "expected-transport-close")
    }

    @Test("Protocol incompatibility is breadcrumb-only")
    func protocolIncompatibilityIsBreadcrumbOnly() {
        let classification = MirageDiagnosticsSubmissionPolicy.classification(
            for: makeEvent(
                category: "client",
                message: "Connection rejected: Mirage versions are incompatible. Host protocol 8, client protocol 7."
            )
        )

        #expect(classification.disposition == .breadcrumbOnly)
        #expect(classification.issueKind == "protocol-incompatible")
    }

    @Test("Breadcrumb-only classifications do not aggregate into Sentry captures")
    func breadcrumbOnlyClassificationsDoNotAggregateIntoSentryCaptures() {
        var state = MirageDiagnosticsSuppressionState()
        let classification = MirageDiagnosticsSubmissionPolicy.classification(
            for: makeEvent(
                category: "host",
                message: "Display current Space restore remained incomplete after delayed verification"
            )
        )
        let now = Date()

        for index in 1...4 {
            let shouldEscalate = state.shouldEscalate(
                classification: classification,
                at: now.addingTimeInterval(Double(index))
            )
            #expect(!shouldEscalate)
        }
        let shouldEscalate = state.shouldEscalate(classification: classification, at: now.addingTimeInterval(5))
        #expect(!shouldEscalate)
    }

    private func makeEvent(
        category: LoomLogCategory,
        message: String,
        metadata: LoomDiagnosticsErrorMetadata? = nil
    ) -> LoomDiagnosticsErrorEvent {
        LoomDiagnosticsErrorEvent(
            date: Date(),
            category: category,
            severity: .error,
            source: .logger,
            message: message,
            fileID: #fileID,
            line: #line,
            function: #function,
            metadata: metadata
        )
    }
}
