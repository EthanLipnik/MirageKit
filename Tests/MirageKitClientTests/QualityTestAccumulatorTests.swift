//
//  QualityTestAccumulatorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//

import Foundation
@testable import MirageKit
@testable import MirageKitClient
import Testing
import MirageWire

@Suite("Quality Test Accumulator")
struct QualityTestAccumulatorTests {
    @Test("Accumulator reports receive span and inter-arrival percentiles")
    func accumulatorReportsReceiveTiming() throws {
        let testID = try #require(UUID(uuidString: "F3AB4316-4175-49E1-8D66-8E1D1DFE0605"))
        let accumulator = QualityTestAccumulator(testID: testID)

        accumulator.record(
            header: header(testID: testID, sequenceNumber: 0),
            payloadBytes: 100,
            receivedAt: 10.000
        )
        accumulator.record(
            header: header(testID: testID, sequenceNumber: 1),
            payloadBytes: 100,
            receivedAt: 10.010
        )
        accumulator.record(
            header: header(testID: testID, sequenceNumber: 2),
            payloadBytes: 100,
            receivedAt: 10.030
        )
        accumulator.record(
            header: header(testID: testID, sequenceNumber: 3),
            payloadBytes: 100,
            receivedAt: 10.050
        )

        let metrics = accumulator.receivedMetrics(for: 7)
        #expect(metrics.receivedPayloadBytes == 400)
        #expect(metrics.receivedPacketCount == 4)
        #expect(abs((metrics.receiveSpanMs ?? 0) - 50) < 0.001)
        #expect(abs((metrics.interArrivalP95Ms ?? 0) - 20) < 0.001)
        #expect(abs((metrics.interArrivalP99Ms ?? 0) - 20) < 0.001)
    }

    private func header(
        testID: UUID,
        sequenceNumber: UInt32
    ) -> MirageWire.QualityTestPacketHeader {
        MirageWire.QualityTestPacketHeader(
            testID: testID,
            stageID: 7,
            sequenceNumber: sequenceNumber,
            timestampNs: 0,
            payloadLength: 100
        )
    }
}
