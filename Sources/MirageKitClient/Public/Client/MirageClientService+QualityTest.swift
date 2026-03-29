//
//  MirageClientService+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Client-side quality test support.
//

import Foundation
import Network
import MirageKit

@MainActor
extension MirageClientService {
    nonisolated static func resolvedQualityTestCandidateBitrate(
        stableBitrateBps: Int,
        measuredBitrateBps: Int
    ) -> Int {
        if stableBitrateBps > 0 { return stableBitrateBps }
        return max(0, measuredBitrateBps)
    }

    public func runQualityTest(
        includeThroughput: Bool = true,
        onStageUpdate: (@MainActor (_ currentStage: Int, _ totalStages: Int) -> Void)? = nil
    ) async throws -> MirageQualityTestSummary {
        guard case .connected = connectionState else {
            throw MirageError.protocolError("Not connected")
        }

        let testID = UUID()
        let payloadBytes = miragePayloadSize(maxPacketSize: networkConfig.maxPacketSize)
        if includeThroughput {
            MirageLogger.client(
                "Quality test starting (payload \(payloadBytes)B, p2p \(networkConfig.enablePeerToPeer), maxPacket \(networkConfig.maxPacketSize)B)"
            )
        } else {
            MirageLogger.client("Quality baseline starting (stream probe only)")
        }
        let rttMs = try await measureRTT()
        let benchmarkTask = Task { try await runDecodeBenchmark() }

        if includeThroughput {
            MirageLogger.client("Quality test: media streams handled via Loom session")
        }

        let hostBenchmarkTask = Task { [weak self] in
            await self?.awaitQualityTestResult(testID: testID, timeout: .seconds(15))
        }
        defer {
            benchmarkTask.cancel()
            hostBenchmarkTask.cancel()
        }

        if !includeThroughput {
            let requestPlan = MirageQualityTestPlan(stages: [])
            let request = QualityTestRequestMessage(
                testID: testID,
                plan: requestPlan,
                payloadBytes: payloadBytes
            )
            try await sendControlMessage(.qualityTestRequest, content: request)
        }

        let minTargetBitrate = 8_000_000
        let maxTargetBitrate = 150_000_000
        let warmupDurationMs = 800
        let stageDurationMs = 1500
        let growthFactor = 1.6
        let maxStages = 8
        let maxRefineSteps = 4
        let plateauThreshold = 0.05
        let plateauLimit = 2
        let minMeasurementStages = 3
        let throughputFloor = 0.9
        let lossCeiling = 2.0
        let totalPlannedStages = estimatedThroughputStageCount(
            minTargetBitrate: minTargetBitrate,
            maxTargetBitrate: maxTargetBitrate,
            growthFactor: growthFactor,
            maxStages: maxStages
        )

        var stageResults: [MirageQualityTestSummary.StageResult] = []
        var stageID = 0
        var measurementStages = 0
        var targetBitrate = minTargetBitrate
        var lastStableBitrate = 0
        var lastStableThroughput = 0
        var lastStableLoss = 0.0
        var candidateBitrate = 0
        var candidateLoss = 0.0
        var plateauCount = 0
        var refining = false
        var refineLow = 0
        var refineHigh = 0
        var refineSteps = 0
        while includeThroughput, stageID < maxStages {
            onStageUpdate?(stageID + 1, totalPlannedStages)
            let durationMs = stageID == 0 ? warmupDurationMs : stageDurationMs
            let stage = try await runQualityTestStage(
                testID: testID,
                stageID: stageID,
                targetBitrateBps: targetBitrate,
                durationMs: durationMs,
                payloadBytes: payloadBytes
            )
            stageResults.append(stage)

            if stageID == 0 {
                stageID += 1
                continue
            }

            measurementStages += 1
            if stage.throughputBps > candidateBitrate {
                candidateBitrate = stage.throughputBps
                candidateLoss = stage.lossPercent
            }
            let isStable = stageIsStable(
                stage,
                targetBitrate: targetBitrate,
                payloadBytes: payloadBytes,
                throughputFloor: throughputFloor,
                lossCeiling: lossCeiling
            )
            if isStable {
                let previousThroughput = lastStableThroughput
                lastStableBitrate = stage.throughputBps
                lastStableThroughput = stage.throughputBps
                lastStableLoss = stage.lossPercent

                if refining {
                    refineLow = targetBitrate
                } else if previousThroughput > 0 {
                    let improvement = Double(lastStableThroughput - previousThroughput) / Double(previousThroughput)
                    if improvement < plateauThreshold {
                        plateauCount += 1
                    } else {
                        plateauCount = 0
                    }
                }

                if !refining {
                    if plateauCount >= plateauLimit, measurementStages >= minMeasurementStages { break }
                    let next = Int(Double(targetBitrate) * growthFactor)
                    if next <= targetBitrate { break }
                    if next > maxTargetBitrate { break }
                    targetBitrate = min(next, maxTargetBitrate)
                }
            } else {
                if lastStableBitrate == 0 {
                    if stage.throughputBps <= 0 || measurementStages >= minMeasurementStages {
                        break
                    }
                    let next = Int(Double(targetBitrate) * growthFactor)
                    if next <= targetBitrate { break }
                    if next > maxTargetBitrate { break }
                    targetBitrate = min(next, maxTargetBitrate)
                    stageID += 1
                    continue
                }
                if !refining {
                    refining = true
                    refineLow = lastStableBitrate
                    refineHigh = targetBitrate
                } else {
                    refineHigh = targetBitrate
                }
            }

            if refining {
                refineSteps += 1
                let ratio = Double(refineHigh) / Double(max(1, refineLow))
                if ratio <= 1.1 || refineSteps >= maxRefineSteps {
                    if measurementStages >= minMeasurementStages { break }
                }
                let next = Int(Double(refineLow) * sqrt(ratio))
                if next <= refineLow { break }
                targetBitrate = min(next, maxTargetBitrate)
            }

            stageID += 1
        }

        let benchmarkRecord = try await benchmarkTask.value
        let hostBenchmark = await hostBenchmarkTask.value
        let maxStableBitrate = Self.resolvedQualityTestCandidateBitrate(
            stableBitrateBps: lastStableBitrate,
            measuredBitrateBps: candidateBitrate
        )
        if maxStableBitrate <= 0 {
            throw MirageError.protocolError("Connection test failed: no usable throughput measurement was recorded.")
        }
        let lossPercent = lastStableBitrate > 0 ? lastStableLoss : candidateLoss

        return MirageQualityTestSummary(
            testID: testID,
            rttMs: rttMs,
            lossPercent: lossPercent,
            maxStableBitrateBps: maxStableBitrate,
            targetFrameRate: getScreenMaxRefreshRate(),
            benchmarkWidth: benchmarkRecord.benchmarkWidth,
            benchmarkHeight: benchmarkRecord.benchmarkHeight,
            hostEncodeMs: hostBenchmark?.encodeMs,
            clientDecodeMs: benchmarkRecord.clientDecodeMs,
            stageResults: stageResults
        )
    }

    /// Run a single in-stream bitrate probe to test if a higher bitrate is sustainable.
    /// Sends test traffic alongside the active stream for a short burst and measures loss.
    /// Returns the stage result with throughput and loss metrics.
    public func runInStreamProbe(
        targetBitrateBps: Int,
        durationMs: Int = 600
    ) async throws -> MirageQualityTestSummary.StageResult {
        guard case .connected = connectionState else {
            throw MirageError.protocolError("Not connected")
        }

        let testID = UUID()
        let payloadBytes = miragePayloadSize(maxPacketSize: networkConfig.maxPacketSize)

        let targetMbps = (Double(targetBitrateBps) / 1_000_000.0)
            .formatted(.number.precision(.fractionLength(1)))
        MirageLogger.client(
            "In-stream probe starting: target \(targetMbps) Mbps, duration \(durationMs)ms"
        )

        let result = try await runQualityTestStage(
            testID: testID,
            stageID: 0,
            targetBitrateBps: targetBitrateBps,
            durationMs: durationMs,
            payloadBytes: payloadBytes
        )

        let throughputMbps = (Double(result.throughputBps) / 1_000_000.0)
            .formatted(.number.precision(.fractionLength(1)))
        let lossText = result.lossPercent
            .formatted(.number.precision(.fractionLength(1)))
        MirageLogger.client(
            "In-stream probe result: throughput \(throughputMbps) Mbps, loss \(lossText)%"
        )

        return result
    }

    func handlePong(_: ControlMessage) {
        completePingRequest(
            expectedRequestID: pingRequestID,
            result: .success(())
        )
    }

    func handleQualityTestResult(_ message: ControlMessage) {
        guard let result = try? message.decode(QualityTestResultMessage.self) else { return }
        guard qualityTestPendingTestID == result.testID else { return }
        completeQualityTestWaiter(
            expectedTestID: result.testID,
            result: result
        )
    }

    private func estimatedThroughputStageCount(
        minTargetBitrate: Int,
        maxTargetBitrate: Int,
        growthFactor: Double,
        maxStages: Int
    ) -> Int {
        guard minTargetBitrate > 0 else { return 0 }
        guard maxStages > 0 else { return 0 }
        guard growthFactor > 1 else { return 1 }

        var count = 0
        var targetBitrate = minTargetBitrate
        while count < maxStages, targetBitrate <= maxTargetBitrate {
            count += 1
            let next = Int(Double(targetBitrate) * growthFactor)
            if next <= targetBitrate { break }
            targetBitrate = next
        }

        return count
    }
}
