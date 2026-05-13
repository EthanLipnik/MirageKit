//
//  MirageClientService+QualityTestHelpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/4/26.
//
//  Helper routines for connection quality tests.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    nonisolated static func validatedQualityTestStageResult(
        _ stageResult: MirageQualityTestSummary.StageResult,
        metrics: (
            sentPayloadBytes: Int,
            receivedPayloadBytes: Int,
            sentPacketCount: Int,
            receivedPacketCount: Int
        )
    ) throws -> MirageQualityTestSummary.StageResult {
        guard metrics.sentPacketCount > 0, metrics.sentPayloadBytes > 0 else {
            throw MirageError.protocolError("Connection test failed: the host did not send any quality-test packets.")
        }
        guard metrics.receivedPacketCount > 0, metrics.receivedPayloadBytes > 0 else {
            throw MirageError.protocolError("Connection test failed: no quality-test packets were received.")
        }
        return stageResult
    }

    nonisolated func handleQualityTestPacket(_ header: QualityTestPacketHeader, data: Data) {
        let context = fastPathState.qualityTestContext
        let accumulator = context.accumulator
        let activeTestID = context.testID
        guard let accumulator, activeTestID == header.testID else { return }
        let payloadBytes = min(Int(header.payloadLength), max(0, data.count - mirageQualityTestHeaderSize))
        accumulator.record(header: header, payloadBytes: payloadBytes)
    }

    /// Cancel the current quality test, if one is active.
    public func cancelActiveQualityTest(
        reason: String,
        notifyHost: Bool = true
    ) async {
        guard let testID = qualityTestPendingTestID else { return }

        MirageLogger.client(
            "Cancelling quality test \(testID.uuidString) reason=\(reason)"
        )

        if notifyHost {
            do {
                try await sendControlMessage(
                    .qualityTestCancel,
                    content: QualityTestCancelMessage(testID: testID)
                )
            } catch {
                MirageLogger.error(.client, error: error, message: "Failed to send qualityTestCancel: ")
            }
        }

        qualityTestPendingTestID = nil
        qualityTestBenchmarkTimeoutTask?.cancel()
        qualityTestBenchmarkTimeoutTask = nil
        qualityTestStageCompletionTimeoutTask?.cancel()
        qualityTestStageCompletionTimeoutTask = nil
        qualityTestStageCompletionBuffer.removeAll()
        fastPathState.clearQualityTestAccumulator()

        failActivePingRequests(with: CancellationError())

        completeQualityTestBenchmarkWaiter(result: nil)
        completeQualityTestStageCompletionWaiter(result: nil)

        if let task = qualityTestStreamReceiveTasks.removeValue(forKey: testID) {
            task.cancel()
        }
        activeMediaStreams.removeValue(forKey: "quality-test/\(testID.uuidString)")
    }

    func runDecodeBenchmark() async throws -> Double {
        try await MirageCodecBenchmarkRunner.runDecodeBenchmark()
    }

    func runQualityTestSession(
        testID: UUID,
        plan: MirageQualityTestPlan,
        payloadBytes: Int,
        mediaMaxPacketSize: Int,
        mode: MirageQualityTestMode,
        stopAfterFirstBreach: Bool,
        onStageUpdate: (@MainActor (MirageQualityTestProgressUpdate) -> Void)? = nil
    ) async throws -> [MirageQualityTestSummary.StageResult] {
        let accumulator = QualityTestAccumulator(testID: testID)
        fastPathState.setQualityTestAccumulator(accumulator, testID: testID)
        qualityTestPendingTestID = testID
        qualityTestStageCompletionBuffer.removeAll()
        defer {
            fastPathState.clearQualityTestAccumulator()
            completeQualityTestStageCompletionWaiter(result: nil)
            qualityTestStageCompletionBuffer.removeAll()
        }

        let request = QualityTestRequestMessage(
            testID: testID,
            plan: plan,
            payloadBytes: payloadBytes,
            mediaMaxPacketSize: mediaMaxPacketSize,
            stopAfterFirstBreach: stopAfterFirstBreach
        )
        try await sendControlMessage(.qualityTestRequest, content: request)

        var results: [MirageQualityTestSummary.StageResult] = []
        for (index, stage) in plan.stages.enumerated() {
            onStageUpdate?(
                MirageQualityTestProgressUpdate(
                    currentStage: index + 1,
                    totalStages: plan.stages.count,
                    completedStages: results.count,
                    probeKind: stage.probeKind,
                    targetBitrateBps: stage.targetBitrateBps,
                    latestCompletedStageResult: results.last
                )
            )
            let timeout = Duration.milliseconds(stage.totalCompletionBudgetMs + Self.qualityTestControlMessageMarginMs)
            guard let completion = await awaitQualityTestStageCompletion(
                testID: testID,
                stageID: stage.id,
                timeout: timeout
            ) else {
                if Task.isCancelled || qualityTestPendingTestID != testID {
                    throw CancellationError()
                }
                await cancelActiveQualityTest(
                    reason: "stage \(stage.id) timed out",
                    notifyHost: true
                )
                throw MirageError.protocolError("Connection test failed: timed out waiting for stage \(stage.id) to finish.")
            }
            let stageResult: MirageQualityTestSummary.StageResult
            do {
                stageResult = try buildQualityTestStageResult(
                    stage,
                    completion: completion,
                    accumulator: accumulator
                )
            } catch {
                await cancelActiveQualityTest(
                    reason: "protocol failure while decoding stage \(stage.id)",
                    notifyHost: true
                )
                throw error
            }
            results.append(stageResult)
            onStageUpdate?(
                MirageQualityTestProgressUpdate(
                    currentStage: index + 1,
                    totalStages: plan.stages.count,
                    completedStages: results.count,
                    probeKind: stage.probeKind,
                    targetBitrateBps: stage.targetBitrateBps,
                    latestCompletedStageResult: stageResult
                )
            )

            let throughputMbps = Double(stageResult.throughputBps) / 1_000_000.0
            let sentMbps = stageResult.durationMs > 0
                ? Double(stageResult.sentPayloadBytes * 8) / (Double(stageResult.durationMs) / 1000.0) / 1_000_000.0
                : 0
            let lossText = stageResult.lossPercent.formatted(.number.precision(.fractionLength(1)))
            MirageLogger.client(
                "Quality test stage \(stage.id) result kind=\(stage.probeKind.rawValue) target \(mirageFormattedMegabitRate(stage.targetBitrateBps)), sent \(sentMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, received \(throughputMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, loss \(lossText)%, packets \(stageResult.receivedPacketCount)/\(stageResult.sentPacketCount)"
            )

            if mode == .connectionLimit,
               Self.qualityTestShouldStopConnectionLimitSweep(stageResult) {
                if index < plan.stages.count - 1 {
                    MirageLogger.client(
                        "Quality test reached \(lossText)% loss at stage \(stage.id); cancelling remaining probe stages"
                    )
                    await cancelActiveQualityTest(
                        reason: "connection-limit loss threshold reached at stage \(stage.id)",
                        notifyHost: true
                    )
                } else {
                    MirageLogger.client(
                        "Quality test reached \(lossText)% loss at final stage \(stage.id)"
                    )
                }
                break
            }

            guard stopAfterFirstBreach else { continue }
            let stabilityConstraints = Self.qualityTestStabilityConstraints(
                for: mode,
                probeKind: stage.probeKind
            )
            let stageStable = Self.qualityTestStageIsStable(
                stageResult,
                targetBitrate: stage.targetBitrateBps,
                payloadBytes: payloadBytes,
                throughputFloor: stabilityConstraints.throughputFloor,
                lossCeiling: stabilityConstraints.lossCeiling
            )
            guard !stageStable else { continue }

            MirageLogger.client(
                "Quality test crossed overload boundary at stage \(stage.id); cancelling remaining probe stages"
            )
            await cancelActiveQualityTest(
                reason: "connection-limit overload boundary reached at stage \(stage.id)",
                notifyHost: true
            )
            break
        }

        return results
    }

    func runQualityTestStage(
        testID: UUID,
        stageID: Int,
        probeKind: MirageQualityTestPlan.ProbeKind = .transport,
        targetBitrateBps: Int,
        durationMs: Int,
        payloadBytes: Int,
        mediaMaxPacketSize: Int
    ) async throws -> MirageQualityTestSummary.StageResult {
        let stage = MirageQualityTestPlan.Stage(
            id: stageID,
            probeKind: probeKind,
            targetBitrateBps: targetBitrateBps,
            durationMs: durationMs
        )
        MirageLogger.client(
            "Quality test stage \(stageID) start: kind \(probeKind.rawValue), target \(mirageFormattedMegabitRate(targetBitrateBps)), duration \(durationMs)ms, payload \(payloadBytes)B"
        )
        let results = try await runQualityTestSession(
            testID: testID,
            plan: MirageQualityTestPlan(stages: [stage]),
            payloadBytes: payloadBytes,
            mediaMaxPacketSize: mediaMaxPacketSize,
            mode: .automaticSelection,
            stopAfterFirstBreach: false
        )
        guard let result = results.first else {
            throw MirageError.protocolError("Connection test failed: no quality-test results were produced.")
        }
        return result
    }

    func buildQualityTestStageResult(
        _ stage: MirageQualityTestPlan.Stage,
        completion: QualityTestStageCompleteMessage,
        accumulator: QualityTestAccumulator
    ) throws -> MirageQualityTestSummary.StageResult {
        guard completion.testID == accumulator.testID else {
            throw MirageError.protocolError("Connection test failed: received stage completion for the wrong test.")
        }
        guard completion.stageID == stage.id else {
            throw MirageError.protocolError("Connection test failed: received stage completion for stage \(completion.stageID) while waiting for \(stage.id).")
        }
        guard completion.probeKind == stage.probeKind else {
            throw MirageError.protocolError("Connection test failed: stage \(stage.id) changed probe kinds mid-session.")
        }

        let receivedMetrics = accumulator.receivedMetrics(for: stage.id)
        let actualDurationMs = max(
            1,
            Int((completion.measurementEndedAtTimestampNs &- completion.startedAtTimestampNs) / 1_000_000)
        )
        let throughputBps = Int(
            Double(receivedMetrics.receivedPayloadBytes * 8) / (Double(actualDurationMs) / 1000.0)
        )
        let lossPercent = completion.sentPacketCount > 0
            ? max(
                0,
                (1 - Double(receivedMetrics.receivedPacketCount) / Double(completion.sentPacketCount)) * 100
            )
            : 0

        let result = MirageQualityTestSummary.StageResult(
            stageID: stage.id,
            probeKind: stage.probeKind,
            targetBitrateBps: stage.targetBitrateBps,
            durationMs: actualDurationMs,
            throughputBps: throughputBps,
            lossPercent: lossPercent,
            sentPacketCount: completion.sentPacketCount,
            receivedPacketCount: receivedMetrics.receivedPacketCount,
            sentPayloadBytes: completion.sentPayloadBytes,
            receivedPayloadBytes: receivedMetrics.receivedPayloadBytes,
            deliveryWindowMissed: completion.deliveryWindowMissed
        )
        return try Self.validatedQualityTestStageResult(
            result,
            metrics: (
                sentPayloadBytes: completion.sentPayloadBytes,
                receivedPayloadBytes: receivedMetrics.receivedPayloadBytes,
                sentPacketCount: completion.sentPacketCount,
                receivedPacketCount: receivedMetrics.receivedPacketCount
            )
        )
    }

}
