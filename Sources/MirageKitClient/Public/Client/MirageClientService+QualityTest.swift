//
//  MirageClientService+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Client-side quality test support.
//

import CoreGraphics
import Foundation
import Network
import MirageKit

@MainActor
extension MirageClientService {
    public func runQualityTest(includeThroughput: Bool = true) async throws -> MirageQualityTestSummary {
        guard case .connected = connectionState, let connection else {
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
            if udpConnection == nil {
                try await startVideoConnection()
            }
            if let udpConnection, let path = udpConnection.currentPath {
                MirageLogger.client("Quality test UDP path: \(describeQualityTestNetworkPath(path))")
            }
            try await sendQualityTestRegistration()
        }

        let hostBenchmarkTask = Task { [weak self] in
            await self?.awaitQualityTestResult(testID: testID, timeout: .seconds(15))
        }

        if !includeThroughput {
            let requestPlan = MirageQualityTestPlan(stages: [])
            let request = QualityTestRequestMessage(
                testID: testID,
                plan: requestPlan,
                payloadBytes: payloadBytes
            )
            let requestMessage = try ControlMessage(type: .qualityTestRequest, content: request)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: requestMessage.serialize(), completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else {
                        continuation.resume()
                    }
                })
            }
        }

        let minTargetBitrate = 20_000_000
        let maxTargetBitrate = 10_000_000_000
        let warmupDurationMs = 800
        let stageDurationMs = 1500
        let growthFactor = 1.6
        let maxStages = 14
        let maxRefineSteps = 4
        let plateauThreshold = 0.05
        let plateauLimit = 2
        let minMeasurementStages = 3
        let throughputFloor = 0.9
        let lossCeiling = 2.0

        var stageResults: [MirageQualityTestSummary.StageResult] = []
        var stageID = 0
        var measurementStages = 0
        var targetBitrate = minTargetBitrate
        var lastStableBitrate = 0
        var lastStableThroughput = 0
        var lastStableLoss = 0.0
        var plateauCount = 0
        var refining = false
        var refineLow = 0
        var refineHigh = 0
        var refineSteps = 0
        while includeThroughput, stageID < maxStages {
            let durationMs = stageID == 0 ? warmupDurationMs : stageDurationMs
            let stage = try await runQualityTestStage(
                testID: testID,
                stageID: stageID,
                targetBitrateBps: targetBitrate,
                durationMs: durationMs,
                payloadBytes: payloadBytes,
                connection: connection
            )
            stageResults.append(stage)

            if stageID == 0 {
                stageID += 1
                continue
            }

            measurementStages += 1
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
                    lastStableBitrate = max(minTargetBitrate, stage.throughputBps)
                    lastStableThroughput = stage.throughputBps
                    lastStableLoss = stage.lossPercent
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
        let maxStableBitrate = max(minTargetBitrate, lastStableBitrate)

        return MirageQualityTestSummary(
            testID: testID,
            rttMs: rttMs,
            lossPercent: lastStableLoss,
            maxStableBitrateBps: maxStableBitrate,
            targetFrameRate: getScreenMaxRefreshRate(),
            benchmarkWidth: benchmarkRecord.benchmarkWidth,
            benchmarkHeight: benchmarkRecord.benchmarkHeight,
            hostEncodeMs: hostBenchmark?.encodeMs,
            clientDecodeMs: benchmarkRecord.clientDecodeMs,
            stageResults: stageResults
        )
    }

    public func runQualityProbe(
        resolution: CGSize,
        pixelFormat: MiragePixelFormat,
        frameRate: Int,
        targetBitrateBps: Int,
        useTransportProbe: Bool = true
    ) async throws -> MirageQualityProbeResult {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        let rawWidth = max(2, Int(resolution.width.rounded(.down)))
        let rawHeight = max(2, Int(resolution.height.rounded(.down)))
        let width = rawWidth - (rawWidth % 2)
        let height = rawHeight - (rawHeight % 2)
        let probeID = UUID()
        let sanitizedFrameRate = max(1, frameRate)
        qualityProbeTransportAccumulator.reset()
        let decodeTask = Task {
            try await runDecodeProbe(
                width: width,
                height: height,
                frameRate: sanitizedFrameRate,
                pixelFormat: pixelFormat
            )
        }

        let transportDurationMs = 2000
        let hostTimeout = Duration.milliseconds(transportDurationMs + 6000)
        let hostTask = Task { [weak self] in
            await self?.awaitQualityProbeResult(probeID: probeID, timeout: hostTimeout)
        }
        var transportConfig: QualityProbeTransportConfig?
        var transportReassembler: FrameReassembler?
        if useTransportProbe {
            do {
                if udpConnection == nil {
                    try await startVideoConnection()
                }
                try await sendQualityTestRegistration()
                let streamID = StreamID.max
                guard controllersByStream[streamID] == nil else {
                    MirageLogger.client("Transport probe skipped - stream ID \(streamID) already active")
                    throw MirageError.protocolError("Transport probe stream ID in use")
                }
                transportConfig = QualityProbeTransportConfig(
                    streamID: streamID,
                    durationMs: transportDurationMs
                )
                transportReassembler = await startQualityProbeTransport(streamID: streamID)
                qualityProbeTransportAccumulator.reset()
            } catch {
                MirageLogger.client("Transport probe disabled: \(error.localizedDescription)")
                transportConfig = nil
                transportReassembler = nil
            }
        }
        let transportStreamID = transportConfig?.streamID
        defer {
            if let streamID = transportStreamID {
                Task { @MainActor in
                    await stopQualityProbeTransport(streamID: streamID)
                }
            }
        }

        let request = QualityProbeRequestMessage(
            probeID: probeID,
            width: width,
            height: height,
            frameRate: sanitizedFrameRate,
            pixelFormat: pixelFormat,
            targetBitrateBps: max(0, targetBitrateBps),
            transportConfig: transportConfig
        )
        let message = try ControlMessage(type: .qualityProbeRequest, content: request)

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: message.serialize(), completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else {
                        continuation.resume()
                    }
                })
            }
        } catch {
            qualityProbeResultContinuation?.resume(returning: nil)
            qualityProbeResultContinuation = nil
            qualityProbePendingID = nil
            decodeTask.cancel()
            throw error
        }

        guard let hostResult = await hostTask.value else {
            decodeTask.cancel()
            throw MirageError.protocolError("Quality probe timed out")
        }

        let decodeMs = try await decodeTask.value
        let transportThroughputBps = transportThroughput()
        let transportLossPercent = transportLoss(reassembler: transportReassembler)
        return MirageQualityProbeResult(
            width: hostResult.width,
            height: hostResult.height,
            frameRate: hostResult.frameRate,
            pixelFormat: hostResult.pixelFormat,
            hostEncodeMs: hostResult.encodeMs,
            clientDecodeMs: decodeMs,
            hostObservedBitrateBps: hostResult.observedBitrateBps,
            transportThroughputBps: transportThroughputBps,
            transportLossPercent: transportLossPercent
        )
    }


    func handlePong(_: ControlMessage) {
        pingContinuation?.resume()
        pingContinuation = nil
    }

    func handleQualityTestResult(_ message: ControlMessage) {
        guard let result = try? message.decode(QualityTestResultMessage.self) else { return }
        guard qualityTestPendingTestID == result.testID else { return }
        qualityTestResultContinuation?.resume(returning: result)
        qualityTestResultContinuation = nil
        qualityTestPendingTestID = nil
    }

    func handleQualityProbeResult(_ message: ControlMessage) {
        guard let result = try? message.decode(QualityProbeResultMessage.self) else { return }
        guard qualityProbePendingID == result.probeID else { return }
        qualityProbeResultContinuation?.resume(returning: result)
        qualityProbeResultContinuation = nil
        qualityProbePendingID = nil
    }
}
