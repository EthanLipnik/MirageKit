//
//  MirageClientService+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Client-side quality test support.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation
import Network

/// Strategy used when building a client-to-host network quality test.
public enum MirageQualityTestMode: Sendable {
    /// Measures transport and replay throughput, then chooses a stable operating point.
    case automaticSelection
    /// Sweeps upward until packet loss crosses the connection limit threshold.
    case connectionLimit
}

/// Incremental progress emitted while a client quality test advances through probe stages.
public struct MirageQualityTestProgressUpdate: Sendable {
    /// One-based index of the stage currently being measured.
    public let currentStage: Int
    /// Total number of planned stages.
    public let totalStages: Int
    /// Number of stages completed before this update.
    public let completedStages: Int
    /// Probe path used by the current stage.
    public let probeKind: MirageDiagnostics.MirageQualityTestPlan.ProbeKind
    /// Target bitrate for the current stage, in bits per second.
    public let targetBitrateBps: Int
    /// Most recent completed stage result, when available.
    public let latestCompletedStageResult: MirageDiagnostics.MirageQualityTestSummary.StageResult?
    /// Bytes transferred so far for object-transfer based tests.
    public let transferredBytes: UInt64?
    /// Total bytes expected for object-transfer based tests.
    public let totalBytes: UInt64?

    /// Creates a quality-test progress update.
    public init(
        currentStage: Int,
        totalStages: Int,
        completedStages: Int,
        probeKind: MirageDiagnostics.MirageQualityTestPlan.ProbeKind,
        targetBitrateBps: Int,
        latestCompletedStageResult: MirageDiagnostics.MirageQualityTestSummary.StageResult?,
        transferredBytes: UInt64? = nil,
        totalBytes: UInt64? = nil
    ) {
        self.currentStage = currentStage
        self.totalStages = totalStages
        self.completedStages = completedStages
        self.probeKind = probeKind
        self.targetBitrateBps = targetBitrateBps
        self.latestCompletedStageResult = latestCompletedStageResult
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
    }
}

@MainActor
extension MirageClientService {
    nonisolated static let qualityTestControlMessageMarginMs = 1500
    nonisolated static let connectionLimitLossThresholdPercent = 1.0

    nonisolated static func qualityTestShouldStopConnectionLimitSweep(
        _ stage: MirageDiagnostics.MirageQualityTestSummary.StageResult
    ) -> Bool {
        stage.lossPercent >= connectionLimitLossThresholdPercent
    }

    /// Runs the negotiated client-to-host quality test and returns the measured summary.
    public func runQualityTest(
        includeThroughput: Bool = true,
        mode: MirageQualityTestMode = .automaticSelection,
        onStageUpdate: (@MainActor (MirageQualityTestProgressUpdate) -> Void)? = nil
    ) async throws -> MirageDiagnostics.MirageQualityTestSummary {
        let testID = UUID()
        return try await withTaskCancellationHandler {
            guard case .connected = connectionState else {
                throw MirageCore.MirageError.protocolError("Not connected")
            }

            qualityTestPendingTestID = testID

            let mediaMaxPacketSize = resolvedRequestedMediaMaxPacketSize
            let payloadBytes = MirageWire.miragePayloadSize(maxPacketSize: mediaMaxPacketSize)
            let usesObjectTransfer = includeThroughput
            let executionPlan =
                includeThroughput && !usesObjectTransfer
                    ? Self.qualityTestExecutionPlan(for: mode)
                    : QualityTestExecutionPlan(
                        plan: MirageDiagnostics.MirageQualityTestPlan(stages: []),
                        transportMeasurementStageIDs: [],
                        streamingReplayMeasurementStageIDs: [],
                        stopAfterFirstBreach: false
                    )

            if includeThroughput {
                if usesObjectTransfer {
                    MirageLogger.client(
                        "Quality test starting object transfer (bytes \(MirageQualityTestTransfer.byteCount), p2p \(networkConfig.enablePeerToPeer), maxPacket \(mediaMaxPacketSize)B)"
                    )
                } else {
                    MirageLogger.client(
                        "Quality test starting (payload \(payloadBytes)B, p2p \(networkConfig.enablePeerToPeer), maxPacket \(mediaMaxPacketSize)B, stages \(executionPlan.plan.stages.count))"
                    )
                }
            } else {
                MirageLogger.client("Quality baseline starting (stream probe only)")
            }

            let benchmarkTask: Task<Double, Error>? = usesObjectTransfer
                ? nil
                : Task { try await runDecodeBenchmark() }
            let hostBenchmarkTimeout = Duration.milliseconds(
                usesObjectTransfer
                    ? 125_000
                    : executionPlan.plan.totalDurationMs + 20000
            )
            let hostBenchmarkTask = Task { [weak self] in
                await self?.awaitQualityTestBenchmark(testID: testID, timeout: hostBenchmarkTimeout)
            }
            defer {
                benchmarkTask?.cancel()
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

            let stageResults: [MirageDiagnostics.MirageQualityTestSummary.StageResult]
            if usesObjectTransfer {
                stageResults = try await runQualityTestObjectTransferSession(
                    testID: testID,
                    payloadBytes: payloadBytes,
                    mediaMaxPacketSize: mediaMaxPacketSize,
                    onStageUpdate: onStageUpdate
                )
            } else {
                stageResults = try await runQualityTestSession(
                    testID: testID,
                    plan: executionPlan.plan,
                    payloadBytes: payloadBytes,
                    mediaMaxPacketSize: mediaMaxPacketSize,
                    mode: mode,
                    stopAfterFirstBreach: executionPlan.stopAfterFirstBreach,
                    onStageUpdate: onStageUpdate
                )
            }

            let clientDecodeMs = try await benchmarkTask?.value
            let hostBenchmark = await hostBenchmarkTask.value

            let resolvedBitrates: (transportHeadroomBps: Int, streamingSafeBitrateBps: Int)
            let lossPercent: Double
            if usesObjectTransfer {
                let measuredThroughputBps = stageResults.map(\.throughputBps).max() ?? 0
                resolvedBitrates = (
                    transportHeadroomBps: measuredThroughputBps,
                    streamingSafeBitrateBps: measuredThroughputBps
                )
                lossPercent = 0
            } else {
                let transportSummary = Self.summarizeQualityTestPhase(
                    stageResults: stageResults,
                    measurementStageIDs: executionPlan.transportMeasurementStageIDs,
                    throughputFloor: Self.qualityTestProfile(for: mode).transport.throughputFloor,
                    lossCeiling: Self.qualityTestProfile(for: mode).transport.lossCeiling,
                    payloadBytes: payloadBytes,
                    requiresLossBelowCeiling: mode == .connectionLimit,
                    allowsMeasuredFallback: mode != .connectionLimit
                )
                let streamingSummary = Self.summarizeQualityTestPhase(
                    stageResults: stageResults,
                    measurementStageIDs: executionPlan.streamingReplayMeasurementStageIDs,
                    throughputFloor: Self.qualityTestProfile(for: mode).streamingReplay.throughputFloor,
                    lossCeiling: Self.qualityTestProfile(for: mode).streamingReplay.lossCeiling,
                    payloadBytes: payloadBytes,
                    requiresLossBelowCeiling: mode == .connectionLimit,
                    allowsMeasuredFallback: mode != .connectionLimit
                )
                resolvedBitrates = Self.resolvedQualityTestSummaryBitrates(
                    mode: mode,
                    transportSummary: transportSummary,
                    streamingSummary: streamingSummary
                )
                lossPercent =
                    streamingSummary.bitrateBps > 0
                        ? streamingSummary.lossPercent : transportSummary.lossPercent
            }

            if resolvedBitrates.transportHeadroomBps <= 0
                && resolvedBitrates.streamingSafeBitrateBps <= 0 {
                throw MirageCore.MirageError.protocolError(
                    "Connection test failed: no usable throughput measurement was recorded."
                )
            }

            return MirageDiagnostics.MirageQualityTestSummary(
                testID: testID,
                rttMs: rttMs,
                lossPercent: lossPercent,
                transportHeadroomBps: resolvedBitrates.transportHeadroomBps,
                streamingSafeBitrateBps: resolvedBitrates.streamingSafeBitrateBps,
                targetFrameRate: screenMaxRefreshRate,
                benchmarkWidth: MirageCodecBenchmarkConstants.benchmarkWidth,
                benchmarkHeight: MirageCodecBenchmarkConstants.benchmarkHeight,
                hostEncodeMs: hostBenchmark?.encodeMs,
                clientDecodeMs: clientDecodeMs,
                hostCaptureCapability: hostBenchmark?.hostCaptureCapability,
                stageResults: stageResults
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await cancelActiveQualityTest(
                    reason: "quality test task cancelled",
                    notifyHost: true
                )
            }
        }
    }

    /// Runs a short in-stream probe at a target bitrate on the active connection.
    public func runInStreamProbe(
        targetBitrateBps: Int,
        durationMs: Int = 600
    ) async throws -> MirageDiagnostics.MirageQualityTestSummary.StageResult {
        guard case .connected = connectionState else {
            throw MirageCore.MirageError.protocolError("Not connected")
        }

        let testID = UUID()
        let mediaMaxPacketSize = resolvedRequestedMediaMaxPacketSize
        let payloadBytes = MirageWire.miragePayloadSize(maxPacketSize: mediaMaxPacketSize)

        MirageLogger.client(
            "In-stream probe starting: target \(mirageFormattedMegabitRate(targetBitrateBps)), duration \(durationMs)ms"
        )

        let result = try await runQualityTestStage(
            testID: testID,
            stageID: 0,
            probeKind: .streamingReplay,
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

    /// Handles the host-side encode benchmark result for the active quality test.
    func handleQualityTestBenchmark(_ message: MirageWire.ControlMessage) {
        let result: MirageWire.QualityTestBenchmarkMessage
        do {
            result = try message.decode(MirageWire.QualityTestBenchmarkMessage.self)
        } catch {
            MirageLogger.error(
                .client, error: error, message: "Failed to decode quality test benchmark: "
            )
            return
        }
        guard qualityTestPendingTestID == result.testID else { return }
        completeQualityTestBenchmarkWaiter(
            expectedTestID: result.testID,
            result: result
        )
    }

    /// Handles a host-reported quality-test stage completion or buffers it until the stage waiter is armed.
    func handleQualityTestStageCompletion(_ message: MirageWire.ControlMessage) {
        let result: MirageWire.QualityTestStageCompleteMessage
        do {
            result = try message.decode(MirageWire.QualityTestStageCompleteMessage.self)
        } catch {
            MirageLogger.error(
                .client, error: error, message: "Failed to decode quality test stage completion: "
            )
            return
        }
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

}
