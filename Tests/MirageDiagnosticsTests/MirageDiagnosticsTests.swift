//
//  MirageDiagnosticsTests.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore
import MirageDiagnostics
import MirageMedia
import Testing

@Suite("MirageDiagnostics")
struct MirageDiagnosticsTests {
    @Test("Classifications expose stable sentry tags")
    func classificationsExposeStableSentryTags() {
        let classification = MirageDiagnostics.MirageDiagnosticsEventClassification(
            disposition: .capture,
            issueKind: "startup",
            failureStage: "first-frame",
            recoveryOutcome: "fallback-exhausted",
            fallbackUsed: "keyframe",
            transportHealth: "packet-starved"
        )

        #expect(classification.sentryTags["mirage_issue_kind"] == "startup")
        #expect(classification.sentryTags["mirage_failure_stage"] == "first-frame")
        #expect(classification.sentryTags["mirage_recovery_outcome"] == "fallback-exhausted")
        #expect(classification.sentryTags["mirage_fallback_used"] == "keyframe")
        #expect(classification.sentryTags["mirage_transport_health"] == "packet-starved")
    }

    @Test("Error metadata snapshots preserve NSError identity")
    func errorMetadataSnapshotsPreserveNSErrorIdentity() {
        let error = NSError(domain: "MirageDiagnosticsTests", code: 42)
        let metadata = MirageDiagnostics.MirageDiagnosticsErrorMetadata(error: error)

        #expect(metadata.typeName == "NSError")
        #expect(metadata.domain == "MirageDiagnosticsTests")
        #expect(metadata.code == 42)
    }

    @Test("Diagnostics context values expose Foundation payloads")
    func diagnosticsContextValuesExposeFoundationPayloads() throws {
        let context: MirageDiagnosticsContext = [
            "string": .string("value"),
            "bool": .bool(true),
            "int": .int(7),
            "double": .double(1.5),
            "array": .array([.int(1), .string("two")]),
            "dictionary": .dictionary(["nested": .bool(false)]),
            "null": .null,
        ]

        #expect(context["string"]?.foundationValue as? String == "value")
        #expect(context["bool"]?.foundationValue as? Bool == true)
        #expect(context["int"]?.foundationValue as? Int == 7)
        #expect(context["double"]?.foundationValue as? Double == 1.5)
        let array = try #require(context["array"]?.foundationValue as? [Any])
        #expect(array[0] as? Int == 1)
        #expect(array[1] as? String == "two")
        let dictionary = try #require(context["dictionary"]?.foundationValue as? [String: Any])
        #expect(dictionary["nested"] as? Bool == false)
        #expect(context["null"]?.foundationValue is NSNull)
    }

    @Test("Suppression state escalates repeated breadcrumb classifications")
    func suppressionStateEscalatesRepeatedBreadcrumbClassifications() {
        var state = MirageDiagnostics.MirageDiagnosticsSuppressionState()
        let classification = MirageDiagnostics.MirageDiagnosticsEventClassification(
            disposition: .breadcrumbOnly,
            issueKind: "expected-disconnect",
            failureStage: "startup",
            recoveryOutcome: "expected-lifecycle",
            suppressionKey: "expected-disconnect:startup:expected-lifecycle"
        )
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let firstEscalation = state.shouldEscalate(classification: classification, at: date, windowThreshold: 3)
        let secondEscalation = state.shouldEscalate(classification: classification, at: date, windowThreshold: 3)
        let thirdEscalation = state.shouldEscalate(classification: classification, at: date, windowThreshold: 3)

        #expect(!firstEscalation)
        #expect(!secondEscalation)
        #expect(thirdEscalation)
    }

    @Test("Submission policy classifies Loom-free event snapshots")
    func submissionPolicyClassifiesLoomFreeEventSnapshots() {
        let expectedDisconnect = MirageDiagnostics.MirageDiagnosticsSubmissionPolicy.classification(
            for: makeDiagnosticsEvent(
                category: "client",
                message: "Desktop stream start failed: Desktop stream client disconnected during startup"
            )
        )
        let reportableTimeout = MirageDiagnostics.MirageDiagnosticsSubmissionPolicy.classification(
            for: makeDiagnosticsEvent(
                category: "client",
                message: "Desktop stream start timed out after 30s"
            )
        )

        #expect(expectedDisconnect.disposition == .breadcrumbOnly)
        #expect(expectedDisconnect.issueKind == "expected-disconnect")
        #expect(reportableTimeout.disposition == .capture)
        #expect(reportableTimeout.issueKind == "desktop-startup-failure")
    }

    @Test("Submission policy preserves metadata-based issue grouping")
    func submissionPolicyPreservesMetadataBasedIssueGrouping() {
        let screencaptureKit = MirageDiagnostics.MirageDiagnosticsSubmissionPolicy.classification(
            for: makeDiagnosticsEvent(
                category: "host",
                message: "Failed to handle desktop stream request: ",
                metadata: MirageDiagnostics.MirageDiagnosticsErrorMetadata(
                    typeName: "NSError",
                    domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                    code: -3813
                )
            )
        )
        let mirageError = MirageDiagnostics.MirageDiagnosticsSubmissionPolicy.classification(
            for: makeDiagnosticsEvent(
                category: "host",
                message: "Unexpected Mirage error",
                metadata: MirageDiagnostics.MirageDiagnosticsErrorMetadata(
                    typeName: "MirageCore.MirageError",
                    domain: "MirageCore.MirageError",
                    code: 0
                )
            )
        )

        #expect(screencaptureKit.issueKind == "screencapturekit-content-list-unavailable")
        #expect(screencaptureKit.failureStage == "capture-start")
        #expect(mirageError.issueKind == "mirage-error")
    }

    @Test("Submission policy keeps expected protocol gates breadcrumb-only")
    func submissionPolicyKeepsExpectedProtocolGatesBreadcrumbOnly() {
        let classification = MirageDiagnostics.MirageDiagnosticsSubmissionPolicy.classification(
            for: makeDiagnosticsEvent(
                category: "client",
                message: "Connection rejected: Mirage versions are incompatible. Host protocol 8, client protocol 7."
            )
        )

        #expect(classification.disposition == .breadcrumbOnly)
        #expect(classification.issueKind == "protocol-incompatible")
        #expect(classification.recoveryOutcome == "expected-version-gate")
    }

    @Test("Submission policy owns first-frame terminal wording")
    func submissionPolicyOwnsFirstFrameTerminalWording() {
        let message = MirageDiagnostics.MirageDiagnosticsSubmissionPolicy.firstFramePresentationFailureTerminalMessage

        #expect(message == "Stream failed to present its first frame after bounded recovery.")
        #expect(MirageDiagnostics.MirageDiagnosticsSubmissionPolicy.isFirstFramePresentationTerminalFailure(message))
    }

    @Test("Instrumentation step events keep stable names")
    func instrumentationStepEventsKeepStableNames() {
        #expect(MirageDiagnostics.MirageStepEvent.clientHelloSent.name == "mirage.client.hello.sent")
        #expect(MirageDiagnostics.MirageStepEvent.clientConnectionRequested.name == "mirage.client.connection.requested")
        #expect(MirageDiagnostics.MirageStepEvent.clientConnectionFailed.name == "mirage.client.connection.failed")
        #expect(MirageDiagnostics.MirageStepEvent.clientConnectionDisconnected.name == "mirage.client.connection.disconnected")
        #expect(MirageDiagnostics.MirageStepEvent.clientHelloAccepted.name == "mirage.client.hello.accepted")
        #expect(
            MirageDiagnostics.MirageStepEvent.clientHelloRejected(.protocolVersionMismatch).name ==
                "mirage.client.hello.rejected.protocol_version_mismatch"
        )
        #expect(MirageDiagnostics.MirageStepEvent.hostClientDisconnected.name == "mirage.host.client.disconnected")
    }

    @Test("Diagnostics lock serializes state updates")
    func diagnosticsLockSerializesStateUpdates() {
        let state = MirageDiagnostics.MirageDiagnosticsLocked(0)

        let updated = state.withLock { value in
            value += 1
            return value
        }
        let observed = state.withLock { $0 }

        #expect(updated == 1)
        #expect(observed == 1)
    }

    @Test("Support archive entries preserve text payload bytes")
    func supportArchiveEntriesPreserveTextPayloadBytes() throws {
        let entry = MirageDiagnostics.MirageLogArchiveEntry(name: "DiagnosticsSummary.txt", text: "summary\n")

        #expect(entry.name == "DiagnosticsSummary.txt")
        #expect(String(data: entry.data, encoding: .utf8) == "summary\n")
    }

    @Test("Client control session summaries keep stable support lines")
    func clientControlSessionSummariesKeepStableSupportLines() {
        let summary = MirageDiagnostics.MirageClientControlSessionAttemptSummary(
            observedAt: Date(timeIntervalSince1970: 0),
            phase: "succeeded",
            hostName: "Studio",
            transport: "udp",
            endpoint: "192.168.1.20:4489",
            candidateKind: "direct",
            routeTier: "preferred",
            endpointSource: "advertisement",
            requiredInterface: "en0",
            proximity: "peer-to-peer",
            outcome: "connected"
        )

        #expect(
            summary.supportSummaryLine ==
                "1970-01-01T00:00:00Z phase=succeeded host=Studio " +
                "transport=udp candidate=direct endpoint=192.168.1.20:4489 " +
                "route=preferred source=advertisement interface=en0 " +
                "proximity=peer-to-peer outcome=connected"
        )
    }

    @Test("Foreground stream health snapshots preserve receiver health fields")
    func foregroundStreamHealthSnapshotsPreserveReceiverHealthFields() {
        let snapshot = MirageForegroundStreamHealthSnapshot(
            streamID: 7,
            hasController: true,
            hasVideoMediaStream: false,
            latestPacketTime: 12.5,
            submittedSequence: 42,
            submittedTime: 13.5,
            visibleFrameFPS: 59.5,
            pendingFrameCount: 2,
            pendingFrameAgeMs: 16.7,
            decodeHealthy: false,
            isAwaitingKeyframe: true
        )

        #expect(snapshot.streamID == 7)
        #expect(snapshot.hasController)
        #expect(!snapshot.hasVideoMediaStream)
        #expect(snapshot.latestPacketTime == 12.5)
        #expect(snapshot.submittedSequence == 42)
        #expect(snapshot.submittedTime == 13.5)
        #expect(snapshot.visibleFrameFPS == 59.5)
        #expect(snapshot.pendingFrameCount == 2)
        #expect(snapshot.pendingFrameAgeMs == 16.7)
        #expect(!snapshot.decodeHealthy)
        #expect(snapshot.isAwaitingKeyframe)
    }

    @Test("Stream snapshots separate session media from logical presentation")
    func streamSnapshotsSeparateSessionMediaFromLogicalPresentation() throws {
        let sessionID = try #require(UUID(uuidString: "33000000-0000-0000-0000-000000000001"))
        let presentationID = try #require(UUID(uuidString: "33000000-0000-0000-0000-000000000002"))
        let ownerID = try #require(UUID(uuidString: "33000000-0000-0000-0000-000000000003"))
        let session = MirageDiagnostics.StreamSessionSnapshot(
            id: sessionID,
            kind: .app,
            streamID: 7,
            mediaStreamID: 42,
            appSessionID: sessionID,
            presentationIDs: [presentationID]
        )
        let presentation = MirageDiagnostics.StreamPresentationSnapshot(
            id: presentationID,
            kind: .appWindow,
            ownerID: ownerID,
            sessionID: session.id,
            streamID: session.streamID,
            mediaStreamID: session.mediaStreamID
        )

        let decodedSession = try JSONDecoder().decode(
            MirageDiagnostics.StreamSessionSnapshot.self,
            from: try JSONEncoder().encode(session)
        )
        let decodedPresentation = try JSONDecoder().decode(
            MirageDiagnostics.StreamPresentationSnapshot.self,
            from: try JSONEncoder().encode(presentation)
        )

        #expect(session.streamID != session.mediaStreamID)
        #expect(presentation.sessionID == session.id)
        #expect(decodedSession == session)
        #expect(decodedPresentation == presentation)
    }

    private func makeDiagnosticsEvent(
        category: String,
        severity: MirageDiagnostics.MirageDiagnosticsErrorSeverity = .error,
        message: String,
        metadata: MirageDiagnostics.MirageDiagnosticsErrorMetadata? = nil
    ) -> MirageDiagnostics.MirageDiagnosticsErrorEventSnapshot {
        MirageDiagnostics.MirageDiagnosticsErrorEventSnapshot(
            category: category,
            severity: severity,
            message: message,
            metadata: metadata
        )
    }
}
