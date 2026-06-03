//
//  QualityTestTransferTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/3/26.
//

import Foundation
import Loom
@testable import MirageKit
import Testing

@Suite("Quality Test Transfer")
struct QualityTestTransferTests {
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
            offer: LoomTransferOffer(logicalName: "test", byteLength: 32),
            bytesWritten: 32
        )

        let metrics = await sink.metrics()
        #expect(metrics.bytesWritten == 32)
        #expect(metrics.completedAtTimestampNs >= metrics.startedAtTimestampNs)
        #expect(metrics.durationMs >= 1)
    }

    @Test("Quality test request requires transfer byte count")
    func requestRequiresTransferByteCount() throws {
        let testID = try #require(UUID(uuidString: "6B22D564-8B1D-4BE3-8AF3-DF48118631E7"))
        let payload = """
        {
          "testID": "\(testID.uuidString)",
          "plan": { "stages": [] },
          "payloadBytes": 1200,
          "mediaMaxPacketSize": 1400,
          "stopAfterFirstBreach": false
        }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(QualityTestRequestMessage.self, from: payload)
        }
    }
}
