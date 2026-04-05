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

    @Test("Automatic execution plan uses replay-only stages")
    func automaticExecutionPlanUsesReplayOnlyStages() {
        let executionPlan = MirageClientService.qualityTestExecutionPlan(for: .automaticSelection)

        #expect(!executionPlan.plan.stages.isEmpty)
        #expect(Set(executionPlan.plan.stages.map(\.probeKind)) == [.streamingReplay])
        #expect(executionPlan.transportMeasurementStageIDs.isEmpty)
        #expect(!executionPlan.streamingReplayMeasurementStageIDs.isEmpty)
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

    @Test("Connection-limit execution plan keeps host-side first-breach termination disabled")
    func connectionLimitExecutionPlanDisablesHostFirstBreachTermination() {
        let executionPlan = MirageClientService.qualityTestExecutionPlan(for: .connectionLimit)

        #expect(!executionPlan.stopAfterFirstBreach)
    }

    @Test("Connection-limit sweep stops at one percent loss")
    func connectionLimitSweepStopsAtOnePercentLoss() {
        let belowThreshold = MirageQualityTestSummary.StageResult(
            stageID: 4,
            probeKind: .transport,
            targetBitrateBps: 512_000_000,
            durationMs: 1_500,
            throughputBps: 508_000_000,
            lossPercent: 0.9,
            sentPacketCount: 10_000,
            receivedPacketCount: 9_910,
            sentPayloadBytes: 80_000_000,
            receivedPayloadBytes: 79_200_000
        )
        let atThreshold = MirageQualityTestSummary.StageResult(
            stageID: 5,
            probeKind: .transport,
            targetBitrateBps: 1_024_000_000,
            durationMs: 1_500,
            throughputBps: 780_000_000,
            lossPercent: 1.0,
            sentPacketCount: 10_000,
            receivedPacketCount: 9_900,
            sentPayloadBytes: 80_000_000,
            receivedPayloadBytes: 78_800_000
        )

        #expect(!MirageClientService.qualityTestShouldStopConnectionLimitSweep(belowThreshold))
        #expect(MirageClientService.qualityTestShouldStopConnectionLimitSweep(atThreshold))
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

    @Test("Connection-limit summary ignores delivery-window misses below one percent loss")
    func connectionLimitSummaryRejectsDeliveryWindowMisses() {
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
                probeKind: .transport,
                targetBitrateBps: 512_000_000,
                durationMs: 1_500,
                throughputBps: 500_000_000,
                lossPercent: 0.4,
                sentPacketCount: 40_000,
                receivedPacketCount: 39_840,
                sentPayloadBytes: 90_000_000,
                receivedPayloadBytes: 89_000_000,
                deliveryWindowMissed: true
            ),
        ]

        let transportSummary = MirageClientService.summarizeQualityTestPhase(
            stageResults: stageResults,
            measurementStageIDs: [1, 2],
            throughputFloor: nil,
            lossCeiling: 1.0,
            payloadBytes: payloadBytes,
            requiresLossBelowCeiling: true,
            allowsMeasuredFallback: false
        )

        #expect(transportSummary.bitrateBps == 240_000_000)
        #expect(transportSummary.lossPercent == 0.2)
    }

    @Test("Connection-limit summary ignores stages at one percent loss")
    func connectionLimitSummaryRejectsOnePercentLossStages() {
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
                probeKind: .transport,
                targetBitrateBps: 512_000_000,
                durationMs: 1_500,
                throughputBps: 470_000_000,
                lossPercent: 1.0,
                sentPacketCount: 40_000,
                receivedPacketCount: 39_600,
                sentPayloadBytes: 90_000_000,
                receivedPayloadBytes: 88_125_000
            ),
        ]

        let transportSummary = MirageClientService.summarizeQualityTestPhase(
            stageResults: stageResults,
            measurementStageIDs: [1, 2],
            throughputFloor: nil,
            lossCeiling: 1.0,
            payloadBytes: payloadBytes,
            requiresLossBelowCeiling: true,
            allowsMeasuredFallback: false
        )

        #expect(transportSummary.bitrateBps == 240_000_000)
        #expect(transportSummary.lossPercent == 0.2)
    }

    @Test("Connection-limit summary does not fall back to unstable measured throughput")
    func connectionLimitSummaryRejectsUnstableCandidateFallback() {
        let transportSummary = MirageClientService.summarizeQualityTestPhase(
            stageResults: [
                MirageQualityTestSummary.StageResult(
                    stageID: 7,
                    probeKind: .transport,
                    targetBitrateBps: 1_024_000_000,
                    durationMs: 1_500,
                    throughputBps: 560_000_000,
                    lossPercent: 0.3,
                    sentPacketCount: 79_654,
                    receivedPacketCount: 79_654,
                    sentPayloadBytes: 105_302_588,
                    receivedPayloadBytes: 105_302_588,
                    deliveryWindowMissed: true
                )
            ],
            measurementStageIDs: [7],
            throughputFloor: nil,
            lossCeiling: 1.0,
            payloadBytes: 1_322,
            requiresLossBelowCeiling: true,
            allowsMeasuredFallback: false
        )

        #expect(transportSummary.bitrateBps == 0)
        #expect(transportSummary.lossPercent == 0)
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

}
