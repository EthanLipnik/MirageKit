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
    nonisolated static let qualityTestObjectTransferStageCompletionTimeout: Duration = .seconds(5)

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
            stopAfterFirstBreach: stopAfterFirstBreach,
            transferByteCount: 0
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

    func runQualityTestObjectTransferSession(
        testID: UUID,
        payloadBytes: Int,
        mediaMaxPacketSize: Int,
        onStageUpdate: (@MainActor (MirageQualityTestProgressUpdate) -> Void)? = nil
    ) async throws -> [MirageQualityTestSummary.StageResult] {
        guard let transferEngine else {
            throw MirageError.protocolError("Missing authenticated Loom transfer engine for connection test")
        }

        let stage = MirageQualityTestPlan.Stage(
            id: MirageQualityTestTransfer.stageID,
            probeKind: .transport,
            targetBitrateBps: 0,
            durationMs: 0,
            settleGraceMs: 0
        )
        let plan = MirageQualityTestPlan(stages: [stage])
        let transferBox = QualityTestOutgoingTransferBox()

        return try await withTaskCancellationHandler {
            qualityTestPendingTestID = testID
            qualityTestStageCompletionBuffer.removeAll()
            defer {
                completeQualityTestStageCompletionWaiter(result: nil)
                qualityTestStageCompletionBuffer.removeAll()
            }

            let request = QualityTestRequestMessage(
                testID: testID,
                plan: plan,
                payloadBytes: payloadBytes,
                mediaMaxPacketSize: mediaMaxPacketSize,
                transferByteCount: MirageQualityTestTransfer.byteCount
            )
            try await sendControlMessage(.qualityTestRequest, content: request)

            onStageUpdate?(
                MirageQualityTestProgressUpdate(
                    currentStage: 1,
                    totalStages: 1,
                    completedStages: 0,
                    probeKind: .transport,
                    targetBitrateBps: 0,
                    latestCompletedStageResult: nil,
                    transferredBytes: 0,
                    totalBytes: MirageQualityTestTransfer.byteCount
                )
            )

            let source = MirageQualityTestNoiseSource()
            let outgoingTransfer = try await transferEngine.offerTransfer(
                LoomTransferOffer(
                    logicalName: MirageQualityTestTransfer.logicalName,
                    byteLength: MirageQualityTestTransfer.byteCount,
                    contentType: "application/octet-stream",
                    metadata: MirageQualityTestTransfer.metadata(testID: testID)
                ),
                source: source
            )
            transferBox.store(outgoingTransfer)

            let progressTask = Task { @MainActor in
                for await progress in outgoingTransfer.makeProgressObserver() {
                    onStageUpdate?(
                        MirageQualityTestProgressUpdate(
                            currentStage: 1,
                            totalStages: 1,
                            completedStages: progress.state == .completed ? 1 : 0,
                            probeKind: .transport,
                            targetBitrateBps: 0,
                            latestCompletedStageResult: nil,
                            transferredBytes: progress.bytesTransferred,
                            totalBytes: progress.totalBytes
                        )
                    )
                }
            }
            defer {
                progressTask.cancel()
            }

            let terminalProgress = await MirageTransferProgress.terminalProgress(
                from: outgoingTransfer.progressEvents
            )
            switch terminalProgress?.state {
            case .completed:
                break
            case .cancelled, .declined:
                throw CancellationError()
            default:
                throw MirageError.protocolError("Connection test transfer did not complete.")
            }

            guard let completion = await awaitQualityTestStageCompletion(
                testID: testID,
                stageID: stage.id,
                timeout: Self.qualityTestObjectTransferStageCompletionTimeout
            ) else {
                throw MirageError.protocolError("Connection test failed: timed out waiting for transfer completion.")
            }
            let stageResult = try buildQualityTestTransferStageResult(completion)
            onStageUpdate?(
                MirageQualityTestProgressUpdate(
                    currentStage: 1,
                    totalStages: 1,
                    completedStages: 1,
                    probeKind: .transport,
                    targetBitrateBps: 0,
                    latestCompletedStageResult: stageResult,
                    transferredBytes: MirageQualityTestTransfer.byteCount,
                    totalBytes: MirageQualityTestTransfer.byteCount
                )
            )
            transferBox.clear()
            return [stageResult]
        } onCancel: {
            Task {
                await transferBox.cancel()
            }
        }
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
            deliveryWindowMissed: completion.deliveryWindowMissed,
            receiveSpanMs: receivedMetrics.receiveSpanMs,
            interArrivalP95Ms: receivedMetrics.interArrivalP95Ms,
            interArrivalP99Ms: receivedMetrics.interArrivalP99Ms,
            deliveryWindowMissReason: completion.deliveryWindowMissed ? "host-delivery-window" : nil
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

    func buildQualityTestTransferStageResult(
        _ completion: QualityTestStageCompleteMessage
    ) throws -> MirageQualityTestSummary.StageResult {
        guard completion.stageID == MirageQualityTestTransfer.stageID else {
            throw MirageError.protocolError("Connection test failed: received transfer completion for stage \(completion.stageID).")
        }
        guard completion.probeKind == .transport else {
            throw MirageError.protocolError("Connection test failed: transfer completion used \(completion.probeKind.rawValue).")
        }
        guard completion.sentPayloadBytes > 0, completion.sentPacketCount > 0 else {
            throw MirageError.protocolError("Connection test failed: no transfer bytes were reported.")
        }

        let actualDurationMs = max(
            1,
            Int((completion.measurementEndedAtTimestampNs &- completion.startedAtTimestampNs) / 1_000_000)
        )
        let throughputBps = Int(
            Double(completion.sentPayloadBytes * 8) / (Double(actualDurationMs) / 1000.0)
        )
        return MirageQualityTestSummary.StageResult(
            stageID: MirageQualityTestTransfer.stageID,
            probeKind: .transport,
            targetBitrateBps: 0,
            durationMs: actualDurationMs,
            throughputBps: throughputBps,
            lossPercent: 0,
            sentPacketCount: completion.sentPacketCount,
            receivedPacketCount: completion.sentPacketCount,
            sentPayloadBytes: completion.sentPayloadBytes,
            receivedPayloadBytes: completion.sentPayloadBytes,
            deliveryWindowMissed: false,
            receiveSpanMs: Double(actualDurationMs),
            interArrivalP95Ms: nil,
            interArrivalP99Ms: nil,
            deliveryWindowMissReason: nil
        )
    }

}

private final class QualityTestOutgoingTransferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var transfer: LoomOutgoingTransfer?

    func store(_ transfer: LoomOutgoingTransfer) {
        lock.lock()
        self.transfer = transfer
        lock.unlock()
    }

    func clear() {
        _ = takeTransfer()
    }

    func cancel() async {
        let transfer = takeTransfer()
        await transfer?.cancel()
    }

    private func takeTransfer() -> LoomOutgoingTransfer? {
        lock.lock()
        defer { lock.unlock() }
        let transfer = transfer
        self.transfer = nil
        return transfer
    }
}
