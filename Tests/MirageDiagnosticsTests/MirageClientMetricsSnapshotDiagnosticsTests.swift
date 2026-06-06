//
//  MirageClientMetricsSnapshotDiagnosticsTests.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageDiagnostics
import MirageMedia
import Testing

@Suite("Client Metrics Snapshot Diagnostics")
struct MirageClientMetricsSnapshotDiagnosticsTests {
    @Test("Host queued-unreliable drop counts summarize categories")
    func hostQueuedUnreliableDropCountsSummarizeCategories() {
        let counts = MirageDiagnostics.MirageHostQueuedUnreliableDropCounts(
            deadlineExpired: 1,
            queueLimit: 2,
            superseded: 3,
            unsupportedTransport: 4,
            closed: 5
        )

        #expect(counts.total == 15)
        #expect(!counts.isEmpty)
    }

    @Test("Metrics snapshot preserves media diagnostics fields")
    func metricsSnapshotPreservesMediaDiagnosticsFields() {
        let snapshot = MirageDiagnostics.MirageClientMetricsSnapshot(
            decodedFPS: 58,
            receivedFPS: 59,
            clientReceiverIngressJitterP95Ms: -1,
            clientReceiverIngressJitterP99Ms: -2,
            hostEncoderRateControlStrategy: .averageBitRateDataRateLimits,
            hostDisplayP3CoverageStatus: .strictCanonical,
            hasHostMetrics: true
        )

        #expect(snapshot.decodedFPS == 58)
        #expect(snapshot.clientReceiverIngressJitterP95Ms == 0)
        #expect(snapshot.clientReceiverIngressJitterP99Ms == 0)
        #expect(snapshot.hostEncoderRateControlStrategy == .averageBitRateDataRateLimits)
        #expect(snapshot.hostDisplayP3CoverageStatus == .strictCanonical)
        #expect(snapshot.hasHostMetrics)
    }

    @Test("Metrics snapshot structured drop counts preserve derived totals")
    func metricsSnapshotStructuredDropCountsPreserveDerivedTotals() {
        var snapshot = MirageDiagnostics.MirageClientMetricsSnapshot(
            clientPresentedFPS: 39,
            submittedFPS: 42,
            uniqueSubmittedFPS: 40
        )
        snapshot.hostStalePacketDrops = 2
        snapshot.hostGenerationAbortDrops = 3
        snapshot.hostNonKeyframeHoldDrops = 5
        snapshot.hostQueuedUnreliableDropCounts = MirageDiagnostics.MirageHostQueuedUnreliableDropCounts(
            deadlineExpired: 7,
            queueLimit: 11
        )
        snapshot.clientRepeatedDeliveredSourceFrameCount = 13
        snapshot.clientDecodeBacklogFrameCount = 17

        #expect(snapshot.submittedFPS == 42)
        #expect(snapshot.uniqueSubmittedFPS == 40)
        #expect(snapshot.clientPresentedFPS == 39)
        #expect(snapshot.clientPresentedFPS > 0)
        let queuedDropCount = snapshot.hostQueuedUnreliableDropCounts?.total ?? 0
        let transportDropCount = (snapshot.hostStalePacketDrops ?? 0) +
            (snapshot.hostSenderLocalDeadlineDrops ?? 0) +
            queuedDropCount
        let senderDropCount = transportDropCount +
            (snapshot.hostGenerationAbortDrops ?? 0) +
            (snapshot.hostNonKeyframeHoldDrops ?? 0)
        #expect(queuedDropCount == 18)
        #expect(transportDropCount == 20)
        #expect(senderDropCount == 28)
        #expect(snapshot.clientRepeatedDeliveredSourceFrameCount == 13)
        #expect(snapshot.clientDecodeBacklogFrameCount == 17)

        snapshot.hostQueuedUnreliableDropCounts = nil

        #expect(snapshot.hostQueuedUnreliableDropCounts == nil)
    }
}
