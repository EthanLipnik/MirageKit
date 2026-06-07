//
//  MirageQualityTestDiagnosticsTests.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageDiagnostics
import Testing

@Suite("Mirage Quality Test Diagnostics")
struct MirageQualityTestDiagnosticsTests {
    @Test("Quality test plans preserve bounded completion budgets")
    func qualityTestPlansPreserveBoundedCompletionBudgets() throws {
        let plan = MirageDiagnostics.MirageQualityTestPlan(stages: [
            MirageDiagnostics.MirageQualityTestPlan.Stage(
                id: 1,
                probeKind: .transport,
                targetBitrateBps: 80_000_000,
                durationMs: 400
            ),
            MirageDiagnostics.MirageQualityTestPlan.Stage(
                id: 2,
                probeKind: .streamingReplay,
                targetBitrateBps: 120_000_000,
                durationMs: 2_000
            ),
            MirageDiagnostics.MirageQualityTestPlan.Stage(
                id: 3,
                probeKind: .transport,
                targetBitrateBps: 40_000_000,
                durationMs: 250,
                settleGraceMs: -10
            ),
        ])

        #expect(plan.stages[0].settleGraceMs == 500)
        #expect(plan.stages[1].settleGraceMs == 1_000)
        #expect(plan.stages[2].settleGraceMs == 0)
        #expect(plan.totalDurationMs == 4_150)

        let decoded = try JSONDecoder().decode(
            MirageDiagnostics.MirageQualityTestPlan.self,
            from: try JSONEncoder().encode(plan)
        )
        #expect(decoded == plan)
    }

    @Test("Quality test summaries preserve stage and capture capability fields")
    func qualityTestSummariesPreserveStageAndCaptureCapabilityFields() throws {
        let testID = try #require(UUID(uuidString: "72000000-0000-0000-0000-000000000001"))
        let capability = MirageDiagnostics.MirageHostCaptureCapability(
            targetFrameRate: 120,
            validThresholdFPS: 60,
            sustainThresholdFPS: 115,
            highestValidPixelWidth: 3840,
            highestValidPixelHeight: 2160,
            highestValidFrameRate: 120,
            highestSustainedPixelWidth: 3840,
            highestSustainedPixelHeight: 2160,
            highestSustainedFrameRate: 118,
            measuredAt: Date(timeIntervalSince1970: 10)
        )
        let stage = MirageDiagnostics.MirageQualityTestSummary.StageResult(
            stageID: 7,
            probeKind: .streamingReplay,
            targetBitrateBps: 96_000_000,
            durationMs: 500,
            throughputBps: 93_000_000,
            lossPercent: 0.25,
            sentPacketCount: 500,
            receivedPacketCount: 498,
            sentPayloadBytes: 6_000_000,
            receivedPayloadBytes: 5_976_000,
            deliveryWindowMissed: true,
            receiveSpanMs: 502.5,
            interArrivalP95Ms: 4.5,
            interArrivalP99Ms: 8.5,
            deliveryWindowMissReason: "settle-window-expired"
        )
        let summary = MirageDiagnostics.MirageQualityTestSummary(
            testID: testID,
            rttMs: 8.2,
            lossPercent: 0.25,
            transportHeadroomBps: 110_000_000,
            streamingSafeBitrateBps: 88_000_000,
            targetFrameRate: 120,
            benchmarkWidth: 1920,
            benchmarkHeight: 1080,
            hostEncodeMs: 5.5,
            clientDecodeMs: 4.5,
            hostCaptureCapability: capability,
            stageResults: [stage]
        )

        #expect(stage.id == 7)
        #expect(summary.stageResults[0].deliveryWindowMissReason == "settle-window-expired")
        #expect(summary.hostCaptureCapability?.highestSustainedPixelCount == 8_294_400)

        let decoded = try JSONDecoder().decode(
            MirageDiagnostics.MirageQualityTestSummary.self,
            from: try JSONEncoder().encode(summary)
        )
        #expect(decoded == summary)
    }
}
