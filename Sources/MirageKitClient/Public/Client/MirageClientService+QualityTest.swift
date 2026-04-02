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

public enum MirageQualityTestMode: Sendable {
    case automaticSelection
    case connectionLimit
}

public struct MirageQualityTestProgressUpdate: Sendable {
    public let currentStage: Int
    public let totalStages: Int
    public let completedStages: Int
    public let probeKind: MirageQualityTestPlan.ProbeKind
    public let targetBitrateBps: Int
    public let latestCompletedStageResult: MirageQualityTestSummary.StageResult?

    public init(
        currentStage: Int,
        totalStages: Int,
        completedStages: Int,
        probeKind: MirageQualityTestPlan.ProbeKind,
        targetBitrateBps: Int,
        latestCompletedStageResult: MirageQualityTestSummary.StageResult?
    ) {
        self.currentStage = currentStage
        self.totalStages = totalStages
        self.completedStages = completedStages
        self.probeKind = probeKind
        self.targetBitrateBps = targetBitrateBps
        self.latestCompletedStageResult = latestCompletedStageResult
    }
}

@MainActor
extension MirageClientService {
    private struct QualityTestProbeProfile {
        let probeKind: MirageQualityTestPlan.ProbeKind
        let minTargetBitrate: Int
        let maxTargetBitrate: Int
        let warmupDurationMs: Int
        let stageDurationMs: Int
        let growthFactor: Double
        let maxStages: Int
        let throughputFloor: Double?
        let lossCeiling: Double
        let includesRefinementTargets: Bool
    }

    private struct QualityTestModeProfile {
        let transport: QualityTestProbeProfile
        let streamingReplay: QualityTestProbeProfile
    }

    struct QualityTestExecutionPlan {
        let plan: MirageQualityTestPlan
        let transportMeasurementStageIDs: Set<Int>
        let streamingReplayMeasurementStageIDs: Set<Int>
        let stopAfterFirstBreach: Bool
    }

    struct QualityTestPhaseSummary {
        let bitrateBps: Int
        let lossPercent: Double
    }

    nonisolated static func resolvedQualityTestCandidateBitrate(
        stableBitrateBps: Int,
        measuredBitrateBps: Int
    ) -> Int {
        if stableBitrateBps > 0 { return stableBitrateBps }
        return max(0, measuredBitrateBps)
    }

    nonisolated static func defaultQualityTestSweepTargets() -> [Int] {
        qualityTestSweepTargets(profile: qualityTestProfile(for: .automaticSelection).transport)
    }

    nonisolated static func connectionLimitQualityTestSweepTargets() -> [Int] {
        qualityTestSweepTargets(profile: qualityTestProfile(for: .connectionLimit).transport)
    }

    nonisolated static func qualityTestSummaryUsesMeasuredThroughput(
        for _: MirageQualityTestMode
    ) -> Bool {
        true
    }

    nonisolated static let qualityTestControlMessageMarginMs = 1_500

    public func runQualityTest(
        includeThroughput: Bool = true,
        mode: MirageQualityTestMode = .automaticSelection,
        onStageUpdate: (@MainActor (MirageQualityTestProgressUpdate) -> Void)? = nil
    ) async throws -> MirageQualityTestSummary {
        let testID = UUID()
        return try await withTaskCancellationHandler {
            guard case .connected = connectionState else {
                throw MirageError.protocolError("Not connected")
            }

            qualityTestPendingTestID = testID

            let mediaMaxPacketSize = resolvedRequestedMediaMaxPacketSize()
            let payloadBytes = miragePayloadSize(maxPacketSize: mediaMaxPacketSize)
            let executionPlan = includeThroughput
                ? Self.qualityTestExecutionPlan(for: mode)
                : QualityTestExecutionPlan(
                    plan: MirageQualityTestPlan(stages: []),
                    transportMeasurementStageIDs: [],
                    streamingReplayMeasurementStageIDs: [],
                    stopAfterFirstBreach: false
                )

            if includeThroughput {
                MirageLogger.client(
                    "Quality test starting (payload \(payloadBytes)B, p2p \(networkConfig.enablePeerToPeer), maxPacket \(mediaMaxPacketSize)B, stages \(executionPlan.plan.stages.count))"
                )
            } else {
                MirageLogger.client("Quality baseline starting (stream probe only)")
            }

            let benchmarkTask = Task { try await runDecodeBenchmark() }
            let hostBenchmarkTimeout = Duration.milliseconds(executionPlan.plan.totalDurationMs + 20_000)
            let hostBenchmarkTask = Task { [weak self] in
                await self?.awaitQualityTestBenchmark(testID: testID, timeout: hostBenchmarkTimeout)
            }
            defer {
                benchmarkTask.cancel()
                hostBenchmarkTask.cancel()
                if qualityTestPendingTestID == testID {
                    qualityTestPendingTestID = nil
                }
                qualityTestStageCompletionBuffer.removeAll()
            }

            let rttMs = try await measureRTT()
            if qualityTestPendingTestID != testID {
                throw CancellationError()
            }
            try Task.checkCancellation()

            let stageResults = try await runQualityTestSession(
                testID: testID,
                plan: executionPlan.plan,
                payloadBytes: payloadBytes,
                mediaMaxPacketSize: mediaMaxPacketSize,
                mode: mode,
                stopAfterFirstBreach: executionPlan.stopAfterFirstBreach,
                onStageUpdate: onStageUpdate
            )

            let benchmarkRecord = try await benchmarkTask.value
            let hostBenchmark = await hostBenchmarkTask.value

            let transportSummary = Self.summarizeQualityTestPhase(
                stageResults: stageResults,
                measurementStageIDs: executionPlan.transportMeasurementStageIDs,
                throughputFloor: Self.qualityTestProfile(for: mode).transport.throughputFloor,
                lossCeiling: Self.qualityTestProfile(for: mode).transport.lossCeiling,
                payloadBytes: payloadBytes
            )
            let streamingSummary = Self.summarizeQualityTestPhase(
                stageResults: stageResults,
                measurementStageIDs: executionPlan.streamingReplayMeasurementStageIDs,
                throughputFloor: Self.qualityTestProfile(for: mode).streamingReplay.throughputFloor,
                lossCeiling: Self.qualityTestProfile(for: mode).streamingReplay.lossCeiling,
                payloadBytes: payloadBytes
            )
            let resolvedBitrates = Self.resolvedQualityTestSummaryBitrates(
                mode: mode,
                transportSummary: transportSummary,
                streamingSummary: streamingSummary
            )

            if resolvedBitrates.transportHeadroomBps <= 0 && resolvedBitrates.streamingSafeBitrateBps <= 0 {
                throw MirageError.protocolError("Connection test failed: no usable throughput measurement was recorded.")
            }

            let lossPercent = streamingSummary.bitrateBps > 0 ? streamingSummary.lossPercent : transportSummary.lossPercent
            return MirageQualityTestSummary(
                testID: testID,
                rttMs: rttMs,
                lossPercent: lossPercent,
                transportHeadroomBps: resolvedBitrates.transportHeadroomBps,
                streamingSafeBitrateBps: resolvedBitrates.streamingSafeBitrateBps,
                targetFrameRate: getScreenMaxRefreshRate(),
                benchmarkWidth: benchmarkRecord.benchmarkWidth,
                benchmarkHeight: benchmarkRecord.benchmarkHeight,
                hostEncodeMs: hostBenchmark?.encodeMs,
                clientDecodeMs: benchmarkRecord.clientDecodeMs,
                stageResults: stageResults
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.cancelActiveQualityTest(
                    reason: "quality test task cancelled",
                    notifyHost: true
                )
            }
        }
    }

    public func runInStreamProbe(
        targetBitrateBps: Int,
        durationMs: Int = 600
    ) async throws -> MirageQualityTestSummary.StageResult {
        guard case .connected = connectionState else {
            throw MirageError.protocolError("Not connected")
        }

        let testID = UUID()
        let mediaMaxPacketSize = resolvedRequestedMediaMaxPacketSize()
        let payloadBytes = miragePayloadSize(maxPacketSize: mediaMaxPacketSize)

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
            payloadBytes: payloadBytes,
            mediaMaxPacketSize: mediaMaxPacketSize
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

    func handleQualityTestBenchmark(_ message: ControlMessage) {
        guard let result = try? message.decode(QualityTestBenchmarkMessage.self) else { return }
        guard qualityTestPendingTestID == result.testID else { return }
        completeQualityTestBenchmarkWaiter(
            expectedTestID: result.testID,
            result: result
        )
    }

    func handleQualityTestStageCompletion(_ message: ControlMessage) {
        guard let result = try? message.decode(QualityTestStageCompleteMessage.self) else { return }
        guard qualityTestPendingTestID == result.testID else { return }

        if qualityTestStageCompletionContinuation != nil {
            completeQualityTestStageCompletionWaiter(
                expectedTestID: result.testID,
                result: result
            )
        } else {
            qualityTestStageCompletionBuffer.append(result)
        }
    }

    nonisolated static func summarizeQualityTestPhase(
        stageResults: [MirageQualityTestSummary.StageResult],
        measurementStageIDs: Set<Int>,
        throughputFloor: Double?,
        lossCeiling: Double,
        payloadBytes: Int
    ) -> QualityTestPhaseSummary {
        let measuredStages = stageResults
            .filter { measurementStageIDs.contains($0.stageID) }
            .sorted { $0.stageID < $1.stageID }

        var lastStableBitrate = 0
        var lastStableLoss = 0.0
        var candidateBitrate = 0
        var candidateLoss = 0.0

        for stage in measuredStages {
            if stage.throughputBps > candidateBitrate {
                candidateBitrate = stage.throughputBps
                candidateLoss = stage.lossPercent
            }
            if qualityTestStageIsStable(
                stage,
                targetBitrate: stage.targetBitrateBps,
                payloadBytes: payloadBytes,
                throughputFloor: throughputFloor,
                lossCeiling: lossCeiling
            ) {
                lastStableBitrate = stage.throughputBps
                lastStableLoss = stage.lossPercent
            }
        }

        let bitrateBps = Self.resolvedQualityTestCandidateBitrate(
            stableBitrateBps: lastStableBitrate,
            measuredBitrateBps: candidateBitrate
        )
        let lossPercent = lastStableBitrate > 0 ? lastStableLoss : candidateLoss
        return QualityTestPhaseSummary(
            bitrateBps: bitrateBps,
            lossPercent: lossPercent
        )
    }

    nonisolated static func resolvedQualityTestSummaryBitrates(
        mode: MirageQualityTestMode,
        transportSummary: QualityTestPhaseSummary,
        streamingSummary: QualityTestPhaseSummary
    ) -> (transportHeadroomBps: Int, streamingSafeBitrateBps: Int) {
        let transportHeadroomBps = transportSummary.bitrateBps
        let streamingSafeBitrateBps: Int
        switch mode {
        case .automaticSelection:
            streamingSafeBitrateBps = streamingSummary.bitrateBps
        case .connectionLimit:
            // Manual connection-limit probes can terminate during transport before any
            // replay stages are sampled. Surface the last clean transport bitrate as the
            // best available safe estimate instead of reporting an artificial zero.
            streamingSafeBitrateBps = streamingSummary.bitrateBps > 0
                ? streamingSummary.bitrateBps
                : transportHeadroomBps
        }

        return (
            transportHeadroomBps: transportHeadroomBps,
            streamingSafeBitrateBps: streamingSafeBitrateBps
        )
    }

    nonisolated static func qualityTestStageIsStable(
        _ stage: MirageQualityTestSummary.StageResult,
        targetBitrate: Int,
        payloadBytes: Int,
        throughputFloor: Double?,
        lossCeiling: Double
    ) -> Bool {
        guard stage.lossPercent <= lossCeiling else { return false }
        guard !stage.deliveryWindowMissed else { return false }
        guard let throughputFloor else { return true }
        let packetBytes = payloadBytes + mirageQualityTestHeaderSize
        let payloadRatio = packetBytes > 0
            ? Double(payloadBytes) / Double(packetBytes)
            : 1.0
        let targetPayloadBps = Double(targetBitrate) * payloadRatio
        return Double(stage.throughputBps) >= targetPayloadBps * throughputFloor
    }

    nonisolated private static func qualityTestProfile(
        for mode: MirageQualityTestMode
    ) -> QualityTestModeProfile {
        switch mode {
        case .automaticSelection:
            return QualityTestModeProfile(
                transport: QualityTestProbeProfile(
                    probeKind: .transport,
                    minTargetBitrate: 8_000_000,
                    maxTargetBitrate: 600_000_000,
                    warmupDurationMs: 800,
                    stageDurationMs: 1_200,
                    growthFactor: 1.55,
                    maxStages: 11,
                    throughputFloor: nil,
                    lossCeiling: 5.0,
                    includesRefinementTargets: false
                ),
                streamingReplay: QualityTestProbeProfile(
                    probeKind: .streamingReplay,
                    minTargetBitrate: 8_000_000,
                    maxTargetBitrate: 600_000_000,
                    warmupDurationMs: 800,
                    stageDurationMs: 1_500,
                    growthFactor: 1.55,
                    maxStages: 11,
                    throughputFloor: 0.9,
                    lossCeiling: 2.0,
                    includesRefinementTargets: true
                )
            )
        case .connectionLimit:
            return QualityTestModeProfile(
                transport: QualityTestProbeProfile(
                    probeKind: .transport,
                    minTargetBitrate: 8_000_000,
                    maxTargetBitrate: 10_000_000_000,
                    warmupDurationMs: 800,
                    stageDurationMs: 1_500,
                    growthFactor: 2.0,
                    maxStages: 16,
                    throughputFloor: nil,
                    lossCeiling: 5.0,
                    includesRefinementTargets: false
                ),
                streamingReplay: QualityTestProbeProfile(
                    probeKind: .streamingReplay,
                    minTargetBitrate: 8_000_000,
                    maxTargetBitrate: 10_000_000_000,
                    warmupDurationMs: 800,
                    stageDurationMs: 1_500,
                    growthFactor: 2.0,
                    maxStages: 16,
                    throughputFloor: 0.9,
                    lossCeiling: 2.0,
                    includesRefinementTargets: false
                )
            )
        }
    }

    nonisolated static func qualityTestExecutionPlan(
        for mode: MirageQualityTestMode
    ) -> QualityTestExecutionPlan {
        let modeProfile = Self.qualityTestProfile(for: mode)
        var stages: [MirageQualityTestPlan.Stage] = []
        var nextStageID = 0

        func appendStages(
            for profile: QualityTestProbeProfile
        ) -> Set<Int> {
            var measurementStageIDs: Set<Int> = []
            let measurementTargets = Self.qualityTestMeasurementTargets(profile: profile)

            stages.append(
                MirageQualityTestPlan.Stage(
                    id: nextStageID,
                    probeKind: profile.probeKind,
                    targetBitrateBps: profile.minTargetBitrate,
                    durationMs: profile.warmupDurationMs
                )
            )
            nextStageID += 1

            for target in measurementTargets {
                let stageID = nextStageID
                stages.append(
                    MirageQualityTestPlan.Stage(
                        id: stageID,
                        probeKind: profile.probeKind,
                        targetBitrateBps: target,
                        durationMs: profile.stageDurationMs
                    )
                )
                measurementStageIDs.insert(stageID)
                nextStageID += 1
            }
            return measurementStageIDs
        }

        let transportMeasurementStageIDs = appendStages(for: modeProfile.transport)
        let streamingReplayMeasurementStageIDs = appendStages(for: modeProfile.streamingReplay)
        return QualityTestExecutionPlan(
            plan: MirageQualityTestPlan(stages: stages),
            transportMeasurementStageIDs: transportMeasurementStageIDs,
            streamingReplayMeasurementStageIDs: streamingReplayMeasurementStageIDs,
            stopAfterFirstBreach: mode == .connectionLimit
        )
    }

    nonisolated static func qualityTestStabilityConstraints(
        for mode: MirageQualityTestMode,
        probeKind: MirageQualityTestPlan.ProbeKind
    ) -> (throughputFloor: Double?, lossCeiling: Double) {
        let modeProfile = qualityTestProfile(for: mode)
        switch probeKind {
        case .transport:
            return (modeProfile.transport.throughputFloor, modeProfile.transport.lossCeiling)
        case .streamingReplay:
            return (modeProfile.streamingReplay.throughputFloor, modeProfile.streamingReplay.lossCeiling)
        }
    }

    nonisolated private static func qualityTestMeasurementTargets(
        profile: QualityTestProbeProfile
    ) -> [Int] {
        let baseTargets = qualityTestSweepTargets(profile: profile)
        guard profile.includesRefinementTargets, baseTargets.count > 1 else {
            return baseTargets
        }

        var targets: [Int] = []
        for (index, lower) in baseTargets.enumerated() {
            targets.append(lower)
            guard index < baseTargets.count - 1 else { continue }
            let upper = baseTargets[index + 1]
            let midpoint = Int(Double(lower) * sqrt(Double(upper) / Double(max(1, lower))))
            if midpoint > lower, midpoint < upper {
                targets.append(midpoint)
            }
        }
        return targets
    }

    nonisolated private static func qualityTestSweepTargets(
        profile: QualityTestProbeProfile
    ) -> [Int] {
        qualityTestSweepTargets(
            minTargetBitrate: profile.minTargetBitrate,
            maxTargetBitrate: profile.maxTargetBitrate,
            growthFactor: profile.growthFactor,
            maxStages: profile.maxStages
        )
    }

    nonisolated private static func qualityTestSweepTargets(
        minTargetBitrate: Int,
        maxTargetBitrate: Int,
        growthFactor: Double,
        maxStages: Int
    ) -> [Int] {
        guard minTargetBitrate > 0 else { return [] }
        guard maxStages > 0 else { return [] }
        guard growthFactor > 1 else { return [minTargetBitrate] }

        var targets: [Int] = []
        var targetBitrate = minTargetBitrate
        while targets.count < maxStages, targetBitrate <= maxTargetBitrate {
            targets.append(targetBitrate)
            let next = Int(Double(targetBitrate) * growthFactor)
            if next <= targetBitrate { break }
            if next > maxTargetBitrate {
                if targets.count < maxStages, targets.last != maxTargetBitrate {
                    targets.append(maxTargetBitrate)
                }
                break
            }
            targetBitrate = next
        }

        return targets
    }
}
