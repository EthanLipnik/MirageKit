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
            probeKind: .transport,
            targetBitrateBps: 8_000_000,
            durationMs: 1_500,
            throughputBps: 0,
            lossPercent: 0,
            sentPacketCount: 1,
            receivedPacketCount: 0,
            sentPayloadBytes: 1_000,
            receivedPayloadBytes: 0
        )

        #expect(throws: Error.self) {
            try MirageClientService.validatedQualityTestStageResult(
                stageResult,
                metrics: (
                    sentPayloadBytes: 1_000,
                    receivedPayloadBytes: 0,
                    sentPacketCount: 1,
                    receivedPacketCount: 0
                )
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
        let first = targets[0]
        let last = targets[targets.count - 1]

        #expect(first == 8_000_000)
        #expect(last >= 600_000_000)
        #expect(targets.count >= 10)
    }

    @Test("Connection-limit throughput sweep reaches the 10 Gbps ceiling")
    func connectionLimitSweepReachesTenGigabits() {
        let targets = MirageClientService.connectionLimitQualityTestSweepTargets()
        let first = targets[0]
        let last = targets[targets.count - 1]

        #expect(first == 8_000_000)
        #expect(last == 10_000_000_000)
        #expect(targets.count >= 12)
    }

    @Test("Connection-limit summary reports measured throughput instead of requested target")
    func connectionLimitSummaryUsesMeasuredThroughput() {
        #expect(MirageClientService.qualityTestSummaryUsesMeasuredThroughput(for: .connectionLimit))
    }

    @Test("Delivery-window misses are treated as unstable even without packet loss")
    func deliveryWindowMissMarksStageUnstableWithoutLoss() {
        let stage = MirageQualityTestSummary.StageResult(
            stageID: 8,
            probeKind: .transport,
            targetBitrateBps: 1_024_000_000,
            durationMs: 1_500,
            throughputBps: 560_000_000,
            lossPercent: 0,
            sentPacketCount: 79_654,
            receivedPacketCount: 79_654,
            sentPayloadBytes: 105_302_588,
            receivedPayloadBytes: 105_302_588,
            deliveryWindowMissed: true
        )

        #expect(
            !MirageClientService.qualityTestStageIsStable(
                stage,
                targetBitrate: stage.targetBitrateBps,
                payloadBytes: 1_322,
                throughputFloor: nil,
                lossCeiling: 5.0
            )
        )
    }

    @Test("Automatic execution plan includes transport and streaming replay phases in one session")
    func automaticExecutionPlanIncludesDualPhaseSession() {
        let executionPlan = MirageClientService.qualityTestExecutionPlan(for: .automaticSelection)

        #expect(!executionPlan.plan.stages.isEmpty)
        #expect(Set(executionPlan.plan.stages.map(\.probeKind)) == [.transport, .streamingReplay])
        #expect(!executionPlan.transportMeasurementStageIDs.isEmpty)
        #expect(!executionPlan.streamingReplayMeasurementStageIDs.isEmpty)
        #expect(executionPlan.transportMeasurementStageIDs.isDisjoint(with: executionPlan.streamingReplayMeasurementStageIDs))

        let lastTransportIndex = executionPlan.plan.stages.lastIndex { $0.probeKind == .transport }
        let firstReplayIndex = executionPlan.plan.stages.firstIndex { $0.probeKind == .streamingReplay }
        #expect(lastTransportIndex != nil)
        #expect(firstReplayIndex != nil)
        #expect((lastTransportIndex ?? 0) < (firstReplayIndex ?? 0))
    }

    @Test("Connection-limit execution plan lets streaming replay sweep to ten gigabits")
    func connectionLimitExecutionPlanLetsStreamingReplaySweepToTenGigabits() {
        let executionPlan = MirageClientService.qualityTestExecutionPlan(for: .connectionLimit)
        let replayTargets = executionPlan.plan.stages
            .filter { $0.probeKind == .streamingReplay }
            .map(\.targetBitrateBps)

        #expect(!replayTargets.isEmpty)
        #expect(replayTargets.contains(10_000_000_000))
    }

    @Test("Streaming replay summary can fall below transport headroom")
    func streamingReplaySummaryCanFallBelowTransportHeadroom() {
        let payloadBytes = 1_122
        let stageResults = [
            MirageQualityTestSummary.StageResult(
                stageID: 1,
                probeKind: .transport,
                targetBitrateBps: 256_000_000,
                durationMs: 1_500,
                throughputBps: 240_000_000,
                lossPercent: 0.2,
                sentPacketCount: 20_000,
                receivedPacketCount: 19_960,
                sentPayloadBytes: 45_000_000,
                receivedPayloadBytes: 44_500_000
            ),
            MirageQualityTestSummary.StageResult(
                stageID: 2,
                probeKind: .streamingReplay,
                targetBitrateBps: 181_000_000,
                durationMs: 1_500,
                throughputBps: 150_000_000,
                lossPercent: 0.1,
                sentPacketCount: 16_000,
                receivedPacketCount: 15_984,
                sentPayloadBytes: 33_900_000,
                receivedPayloadBytes: 28_125_000
            )
        ]

        let transportSummary = MirageClientService.summarizeQualityTestPhase(
            stageResults: stageResults,
            measurementStageIDs: [1],
            throughputFloor: nil,
            lossCeiling: 5.0,
            payloadBytes: payloadBytes
        )
        let streamingReplaySummary = MirageClientService.summarizeQualityTestPhase(
            stageResults: stageResults,
            measurementStageIDs: [2],
            throughputFloor: 0.9,
            lossCeiling: 2.0,
            payloadBytes: payloadBytes
        )

        #expect(transportSummary.bitrateBps == 240_000_000)
        #expect(streamingReplaySummary.bitrateBps == 150_000_000)
        #expect(streamingReplaySummary.bitrateBps < transportSummary.bitrateBps)
    }

    @Test("Connection-limit summary falls back to transport bitrate when replay stages are unmeasured")
    func connectionLimitSummaryFallsBackToTransportBitrate() {
        let resolved = MirageClientService.resolvedQualityTestSummaryBitrates(
            mode: .connectionLimit,
            transportSummary: .init(bitrateBps: 31_000_000, lossPercent: 0),
            streamingSummary: .init(bitrateBps: 0, lossPercent: 0)
        )

        #expect(resolved.transportHeadroomBps == 31_000_000)
        #expect(resolved.streamingSafeBitrateBps == 31_000_000)
    }

    @Test("Automatic summary keeps replay bitrate at zero when replay stages are unmeasured")
    func automaticSummaryDoesNotBackfillReplayBitrate() {
        let resolved = MirageClientService.resolvedQualityTestSummaryBitrates(
            mode: .automaticSelection,
            transportSummary: .init(bitrateBps: 31_000_000, lossPercent: 0),
            streamingSummary: .init(bitrateBps: 0, lossPercent: 0)
        )

        #expect(resolved.transportHeadroomBps == 31_000_000)
        #expect(resolved.streamingSafeBitrateBps == 0)
    }

    @Test("Automatic startup probe plan uses the fixed four-stage replay sweep")
    func automaticStartupProbePlanUsesFixedReplaySweep() throws {
        let desiredBitrateBps = 200_000_000
        let plan = MirageClientService.automaticStartupProbePlan(desiredBitrateBps: desiredBitrateBps)

        #expect(plan.stages.count == 4)
        #expect(plan.stages.map(\.probeKind) == [.streamingReplay, .streamingReplay, .streamingReplay, .streamingReplay])
        #expect(plan.stages.map(\.durationMs) == [500, 900, 1_100, 1_300])
        #expect(plan.stages.map(\.targetBitrateBps) == [100_000_000, 140_000_000, 170_000_000, 200_000_000])
    }

    @Test("Automatic startup probe configuration uses the shared bitrate-quality mapper")
    func automaticStartupProbeConfigurationUsesSharedQualityMapper() throws {
        let configuration = try #require(
            MirageClientService.automaticStartupProbeConfiguration(
                encodedWidth: 5_120,
                encodedHeight: 2_880,
                targetFrameRate: 60
            )
        )
        let expectedBitrate = try #require(
            MirageBitrateQualityMapper.targetBitrateBps(
                forFrameQuality: 0.75,
                width: 5_120,
                height: 2_880,
                frameRate: 60
            )
        )

        #expect(configuration.desiredBitrateBps == expectedBitrate)
    }

    @Test("Automatic startup probe picks the highest stable measured throughput")
    func automaticStartupProbePicksHighestStableMeasuredThroughput() {
        let payloadBytes = 1_322
        let stageResults = [
            MirageQualityTestSummary.StageResult(
                stageID: 0,
                probeKind: .streamingReplay,
                targetBitrateBps: 100_000_000,
                durationMs: 500,
                throughputBps: 96_000_000,
                lossPercent: 0.2,
                sentPacketCount: 10_000,
                receivedPacketCount: 9_980,
                sentPayloadBytes: 6_250_000,
                receivedPayloadBytes: 6_000_000
            ),
            MirageQualityTestSummary.StageResult(
                stageID: 1,
                probeKind: .streamingReplay,
                targetBitrateBps: 140_000_000,
                durationMs: 900,
                throughputBps: 132_000_000,
                lossPercent: 0.5,
                sentPacketCount: 14_000,
                receivedPacketCount: 13_930,
                sentPayloadBytes: 15_750_000,
                receivedPayloadBytes: 14_850_000
            ),
            MirageQualityTestSummary.StageResult(
                stageID: 2,
                probeKind: .streamingReplay,
                targetBitrateBps: 170_000_000,
                durationMs: 1_100,
                throughputBps: 168_000_000,
                lossPercent: 0.7,
                sentPacketCount: 17_000,
                receivedPacketCount: 16_880,
                sentPayloadBytes: 23_375_000,
                receivedPayloadBytes: 23_100_000
            ),
            MirageQualityTestSummary.StageResult(
                stageID: 3,
                probeKind: .streamingReplay,
                targetBitrateBps: 200_000_000,
                durationMs: 1_300,
                throughputBps: 188_000_000,
                lossPercent: 1.4,
                sentPacketCount: 20_000,
                receivedPacketCount: 19_720,
                sentPayloadBytes: 32_500_000,
                receivedPayloadBytes: 30_550_000
            ),
        ]

        let resolved = MirageClientService.resolvedAutomaticStartupProbeBitrate(
            stageResults: stageResults,
            payloadBytes: payloadBytes
        )

        #expect(resolved.startupBitrateBps == 168_000_000)
        #expect(resolved.selectedStageResult?.stageID == 2)
        #expect(resolved.peakMeasuredBitrateBps == 188_000_000)
    }

    @Test("Automatic startup probe falls back to the highest measured throughput when no stage is stable")
    func automaticStartupProbeFallsBackToHighestMeasuredThroughput() {
        let payloadBytes = 1_322
        let stageResults = [
            MirageQualityTestSummary.StageResult(
                stageID: 0,
                probeKind: .streamingReplay,
                targetBitrateBps: 100_000_000,
                durationMs: 500,
                throughputBps: 82_000_000,
                lossPercent: 1.3,
                sentPacketCount: 10_000,
                receivedPacketCount: 9_840,
                sentPayloadBytes: 6_250_000,
                receivedPayloadBytes: 5_125_000
            ),
            MirageQualityTestSummary.StageResult(
                stageID: 1,
                probeKind: .streamingReplay,
                targetBitrateBps: 140_000_000,
                durationMs: 900,
                throughputBps: 121_000_000,
                lossPercent: 1.5,
                sentPacketCount: 14_000,
                receivedPacketCount: 13_790,
                sentPayloadBytes: 15_750_000,
                receivedPayloadBytes: 13_612_500
            ),
            MirageQualityTestSummary.StageResult(
                stageID: 2,
                probeKind: .streamingReplay,
                targetBitrateBps: 170_000_000,
                durationMs: 1_100,
                throughputBps: 152_000_000,
                lossPercent: 1.2,
                sentPacketCount: 17_000,
                receivedPacketCount: 16_796,
                sentPayloadBytes: 23_375_000,
                receivedPayloadBytes: 20_900_000
            ),
        ]

        let resolved = MirageClientService.resolvedAutomaticStartupProbeBitrate(
            stageResults: stageResults,
            payloadBytes: payloadBytes
        )

        #expect(resolved.startupBitrateBps == 152_000_000)
        #expect(resolved.selectedStageResult?.stageID == 2)
        #expect(resolved.peakMeasuredBitrateBps == 152_000_000)
    }
}
