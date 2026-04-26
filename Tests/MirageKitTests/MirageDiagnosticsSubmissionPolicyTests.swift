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

    @Test("Suppressed classes escalate on repeated launch and window counts")
    func suppressedClassesEscalateOnRepeatedCounts() {
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
        #expect(shouldEscalate)
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
