//
//  QualityTestTransportTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/29/26.
//

@testable import MirageKitClient
import Foundation
import MirageKit
import Testing

@Suite("Quality Test Transport")
struct QualityTestTransportTests {
    @Test("Incoming media stream classification accepts quality-test labels")
    func incomingMediaStreamClassificationAcceptsQualityTestLabels() {
        let testID = UUID()
        #expect(IncomingMediaStreamKind.classify(label: "quality-test/\(testID.uuidString)") == .qualityTest(testID))
        #expect(IncomingMediaStreamKind.classify(label: "video/42") == .video(42))
        #expect(IncomingMediaStreamKind.classify(label: "audio/7") == .audio(7))
        #expect(IncomingMediaStreamKind.classify(label: "quality-test/not-a-uuid") == .unknown)
    }

    @Test("Zero-packet stage metrics fail validation instead of reporting synthetic loss")
    func zeroPacketStageMetricsFailValidation() throws {
        let stageResult = MirageQualityTestSummary.StageResult(
            stageID: 1,
            targetBitrateBps: 8_000_000,
            durationMs: 1_500,
            throughputBps: 0,
            lossPercent: 0
        )

        #expect(throws: Error.self) {
            try MirageClientService.validatedQualityTestStageResult(
                stageResult,
                metrics: (expectedBytes: 1_000, receivedBytes: 0, packetCount: 0)
            )
        }
    }

    @Test("Measured throughput becomes candidate bitrate when no stable stage exists")
    func measuredThroughputBecomesCandidateBitrate() {
        #expect(
            MirageClientService.resolvedQualityTestCandidateBitrate(
                stableBitrateBps: 0,
                measuredBitrateBps: 6_500_000
            ) == 6_500_000
        )
        #expect(
            MirageClientService.resolvedQualityTestCandidateBitrate(
                stableBitrateBps: 12_000_000,
                measuredBitrateBps: 6_500_000
            ) == 12_000_000
        )
    }

    @Test("Default throughput sweep can climb into the 600 Mbps range")
    func defaultThroughputSweepReachesSixHundredMegabits() {
        let targets = MirageClientService.defaultQualityTestSweepTargets()
        let first = try? #require(targets.first)
        let last = try? #require(targets.last)

        #expect(first == 8_000_000)
        #expect((last ?? 0) >= 600_000_000)
        #expect(targets.count >= 10)
    }
}
