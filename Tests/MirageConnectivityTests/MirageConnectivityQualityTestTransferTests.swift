//
//  MirageConnectivityQualityTestTransferTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
@testable import MirageConnectivity
import Testing

@Suite("Mirage Connectivity Quality Test Transfer")
struct MirageConnectivityQualityTestTransferTests {
    @Test("Noise source is deterministic non-zero data")
    func noiseSourceIsDeterministicNonZeroData() async throws {
        let source = MirageQualityTestNoiseSource(byteLength: 4096)

        let first = try await source.read(offset: 128, maxLength: 512)
        let repeated = try await source.read(offset: 128, maxLength: 512)
        let shifted = try await source.read(offset: 129, maxLength: 512)

        #expect(first.count == 512)
        #expect(first == repeated)
        #expect(first != shifted)
        #expect(first.contains { $0 != 0 })
    }

    @Test("Discard sink records byte count and timing")
    func discardSinkRecordsByteCountAndTiming() async throws {
        let sink = MirageQualityTestDiscardSink()

        try await sink.write(Data(repeating: 0xaa, count: 16), at: 0)
        try await Task.sleep(for: .milliseconds(2))
        try await sink.write(Data(repeating: 0xbb, count: 16), at: 16)
        try await sink.finalize(
            offer: MirageTransferOffer(logicalName: "test", byteLength: 32),
            bytesWritten: 32
        )

        let metrics = await sink.metrics()
        #expect(metrics.bytesWritten == 32)
        #expect(metrics.completedAtTimestampNs >= metrics.startedAtTimestampNs)
        #expect(metrics.durationMs >= 1)
    }
}
