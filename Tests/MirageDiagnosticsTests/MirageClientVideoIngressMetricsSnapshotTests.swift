//
//  MirageClientVideoIngressMetricsSnapshotTests.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageDiagnostics
import Testing

@Suite("Mirage Client Video Ingress Metrics Snapshot")
struct MirageClientVideoIngressMetricsSnapshotTests {
    @Test("Client video ingress metrics preserve telemetry fields")
    func clientVideoIngressMetricsPreserveTelemetryFields() {
        let snapshot = MirageClientVideoIngressMetricsSnapshot(
            loomStreamDeliveryPPS: 120,
            loomStreamDeliveryIntervalMaxMs: 18,
            rawPacketIngressPPS: 240,
            incomingBatchRate: 60,
            incomingBatchIntervalP95Ms: 12,
            incomingBatchIntervalP99Ms: 16,
            incomingBatchIntervalMaxMs: 22,
            incomingBatchMaxSize: 6,
            incomingBatchAverageSize: 2.5,
            queuedBatchCount: 3,
            queuedPacketCount: 18,
            queueAgeMaxMs: 7,
            stalePacketDropCount: 2,
            overloadPacketDropCount: 4,
            protectedOverloadPacketDropCount: 1,
            processedPacketCount: 1200,
            processorWakeDelayMaxMs: 3.5
        )

        #expect(snapshot.loomStreamDeliveryPPS == 120)
        #expect(snapshot.incomingBatchAverageSize == 2.5)
        #expect(snapshot.queuedPacketCount == 18)
        #expect(snapshot.protectedOverloadPacketDropCount == 1)
        #expect(snapshot.processedPacketCount == 1200)
        #expect(snapshot.processorWakeDelayMaxMs == 3.5)
    }

    @Test("Client video ingress metrics are equatable")
    func clientVideoIngressMetricsAreEquatable() {
        let first = makeSnapshot(processedPacketCount: 4)
        let matching = makeSnapshot(processedPacketCount: 4)
        let different = makeSnapshot(processedPacketCount: 5)

        #expect(first == matching)
        #expect(first != different)
    }

    private func makeSnapshot(processedPacketCount: UInt64) -> MirageClientVideoIngressMetricsSnapshot {
        MirageClientVideoIngressMetricsSnapshot(
            loomStreamDeliveryPPS: 1,
            loomStreamDeliveryIntervalMaxMs: 2,
            rawPacketIngressPPS: 3,
            incomingBatchRate: 4,
            incomingBatchIntervalP95Ms: 5,
            incomingBatchIntervalP99Ms: 6,
            incomingBatchIntervalMaxMs: 7,
            incomingBatchMaxSize: 8,
            incomingBatchAverageSize: 9,
            queuedBatchCount: 10,
            queuedPacketCount: 11,
            queueAgeMaxMs: 12,
            stalePacketDropCount: 13,
            overloadPacketDropCount: 14,
            protectedOverloadPacketDropCount: 15,
            processedPacketCount: processedPacketCount,
            processorWakeDelayMaxMs: 16
        )
    }
}
