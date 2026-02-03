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

@MainActor
extension MirageClientService {
    public func runQualityTest() async throws -> MirageQualityTestSummary {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        let testID = UUID()
        let payloadBytes = miragePayloadSize(maxPacketSize: networkConfig.maxPacketSize)
        MirageLogger.client(
            "Quality test starting (payload \(payloadBytes)B, p2p \(networkConfig.enablePeerToPeer), maxPacket \(networkConfig.maxPacketSize)B)"
        )
        let rttMs = try await measureRTT()
        let benchmarkTask = Task { try await ensureDecodeBenchmark() }

        if udpConnection == nil {
            try await startVideoConnection()
        }
        if let udpConnection, let path = udpConnection.currentPath {
            MirageLogger.client("Quality test UDP path: \(describeNetworkPath(path))")
        }
        try await sendQualityTestRegistration()

        let hostBenchmarkTask = Task { [weak self] in
            await self?.awaitQualityTestResult(testID: testID, timeout: .seconds(15))
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
        var includeBenchmark = true

        while stageID < maxStages {
            let durationMs = stageID == 0 ? warmupDurationMs : stageDurationMs
            let stage = try await runQualityTestStage(
                testID: testID,
                stageID: stageID,
                targetBitrateBps: targetBitrate,
                durationMs: durationMs,
                payloadBytes: payloadBytes,
                includeCodecBenchmark: includeBenchmark,
                connection: connection
            )
            includeBenchmark = false
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
                lastStableBitrate = targetBitrate
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

    nonisolated func handleQualityTestPacket(_ header: QualityTestPacketHeader, data: Data) {
        qualityTestLock.lock()
        let accumulator = qualityTestAccumulatorStorage
        let activeTestID = qualityTestActiveTestIDStorage
        qualityTestLock.unlock()

        guard let accumulator, activeTestID == header.testID else { return }
        let payloadBytes = min(Int(header.payloadLength), max(0, data.count - mirageQualityTestHeaderSize))
        accumulator.record(stageID: Int(header.stageID), payloadBytes: payloadBytes)
    }

    private func measureRTT() async throws -> Double {
        var samples: [Double] = []

        for _ in 0 ..< 3 {
            let start = CFAbsoluteTimeGetCurrent()
            try await sendPingAndAwaitPong()
            let delta = (CFAbsoluteTimeGetCurrent() - start) * 1000
            samples.append(delta)
        }

        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private func sendPingAndAwaitPong() async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }
        guard pingContinuation == nil else {
            throw MirageError.protocolError("Ping already in flight")
        }

        let message = ControlMessage(type: .ping)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pingContinuation = continuation
            connection.send(content: message.serialize(), completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    pingContinuation?.resume(throwing: error)
                    pingContinuation = nil
                }
            })

            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(1))
                if let pingContinuation = self.pingContinuation {
                    pingContinuation.resume(throwing: MirageError.protocolError("Ping timed out"))
                    self.pingContinuation = nil
                }
            }
        }
    }

    private func awaitQualityTestResult(testID: UUID, timeout: Duration) async -> QualityTestResultMessage? {
        if let pending = qualityTestPendingTestID, pending != testID {
            qualityTestResultContinuation?.resume(returning: nil)
            qualityTestResultContinuation = nil
        }

        qualityTestPendingTestID = testID

        return await withCheckedContinuation { continuation in
            qualityTestResultContinuation = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: timeout)
                guard let continuation = self.qualityTestResultContinuation else { return }
                continuation.resume(returning: nil)
                self.qualityTestResultContinuation = nil
                self.qualityTestPendingTestID = nil
            }
        }
    }

    private func sendQualityTestRegistration() async throws {
        guard let udpConnection else {
            throw MirageError.protocolError("No UDP connection")
        }

        var data = Data()
        data.append(contentsOf: [0x4D, 0x49, 0x52, 0x51])
        withUnsafeBytes(of: deviceID.uuid) { data.append(contentsOf: $0) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            udpConnection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }
    }

    private func ensureDecodeBenchmark() async throws -> MirageCodecBenchmarkStore.Record {
        let store = MirageCodecBenchmarkStore()
        if let record = store.load(),
           record.version == MirageCodecBenchmarkStore.currentVersion,
           record.clientDecodeMs != nil {
            return record
        }

        let decodeMs = try await MirageCodecBenchmark.runDecodeBenchmark()
        let record = MirageCodecBenchmarkStore.Record(
            version: MirageCodecBenchmarkStore.currentVersion,
            benchmarkWidth: MirageCodecBenchmark.benchmarkWidth,
            benchmarkHeight: MirageCodecBenchmark.benchmarkHeight,
            benchmarkFrameRate: MirageCodecBenchmark.benchmarkFrameRate,
            hostEncodeMs: nil,
            clientDecodeMs: decodeMs,
            measuredAt: Date()
        )
        store.save(record)
        return record
    }

    private func runQualityTestStage(
        testID: UUID,
        stageID: Int,
        targetBitrateBps: Int,
        durationMs: Int,
        payloadBytes: Int,
        includeCodecBenchmark: Bool,
        connection: NWConnection
    ) async throws -> MirageQualityTestSummary.StageResult {
        let stage = MirageQualityTestPlan.Stage(
            id: stageID,
            targetBitrateBps: targetBitrateBps,
            durationMs: durationMs
        )
        let plan = MirageQualityTestPlan(stages: [stage])
        let accumulator = QualityTestAccumulator(testID: testID, plan: plan, payloadBytes: payloadBytes)
        setQualityTestAccumulator(accumulator, testID: testID)
        defer { clearQualityTestAccumulator() }

        let targetMbps = Double(targetBitrateBps) / 1_000_000.0
        MirageLogger.client(
            "Quality test stage \(stageID) start: target \(targetMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, duration \(durationMs)ms, payload \(payloadBytes)B, includeBenchmark \(includeCodecBenchmark)"
        )

        let request = QualityTestRequestMessage(
            testID: testID,
            plan: plan,
            payloadBytes: payloadBytes,
            includeCodecBenchmark: includeCodecBenchmark
        )
        let message = try ControlMessage(type: .qualityTestRequest, content: request)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: message.serialize(), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }

        try await Task.sleep(for: .milliseconds(durationMs + 400))
        try Task.checkCancellation()

        let results = accumulator.makeStageResults()
        if let stageResult = results.first {
            let metrics = accumulator.stageMetrics(for: stage)
            let throughputMbps = Double(stageResult.throughputBps) / 1_000_000.0
            let lossText = stageResult.lossPercent.formatted(.number.precision(.fractionLength(1)))
            MirageLogger.client(
                "Quality test stage \(stageID) result: throughput \(throughputMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, loss \(lossText)%, received \(metrics.receivedBytes)B, expected \(metrics.expectedBytes)B, packets \(metrics.packetCount)"
            )
            return stageResult
        }

        return MirageQualityTestSummary.StageResult(
            stageID: stageID,
            targetBitrateBps: targetBitrateBps,
            durationMs: durationMs,
            throughputBps: 0,
            lossPercent: 100
        )
    }

    private func stageIsStable(
        _ stage: MirageQualityTestSummary.StageResult,
        targetBitrate: Int,
        payloadBytes: Int,
        throughputFloor: Double,
        lossCeiling: Double
    ) -> Bool {
        let packetBytes = payloadBytes + mirageQualityTestHeaderSize
        let payloadRatio = packetBytes > 0
            ? Double(payloadBytes) / Double(packetBytes)
            : 1.0
        let targetPayloadBps = Double(targetBitrate) * payloadRatio
        let throughputOk = Double(stage.throughputBps) >= targetPayloadBps * throughputFloor
        let lossOk = stage.lossPercent <= lossCeiling
        return throughputOk && lossOk
    }

    nonisolated private func setQualityTestAccumulator(_ accumulator: QualityTestAccumulator, testID: UUID) {
        qualityTestLock.lock()
        qualityTestAccumulatorStorage = accumulator
        qualityTestActiveTestIDStorage = testID
        qualityTestLock.unlock()
    }

    private func clearQualityTestAccumulator() {
        qualityTestLock.lock()
        qualityTestAccumulatorStorage = nil
        qualityTestActiveTestIDStorage = nil
        qualityTestLock.unlock()
    }
}

private func describeNetworkPath(_ path: NWPath) -> String {
    var interfaces: [String] = []
    if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
    if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wired") }
    if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
    if path.usesInterfaceType(.loopback) { interfaces.append("loopback") }
    if path.usesInterfaceType(.other) { interfaces.append("other") }
    let interfaceText = interfaces.isEmpty ? "unknown" : interfaces.joined(separator: ",")
    let available = path.availableInterfaces
        .map { "\($0.name)(\(String(describing: $0.type)))" }
        .joined(separator: ",")
    let availableText = available.isEmpty ? "none" : available
    return "status=\(path.status), interfaces=\(interfaceText), available=\(availableText), expensive=\(path.isExpensive), constrained=\(path.isConstrained), ipv4=\(path.supportsIPv4), ipv6=\(path.supportsIPv6)"
}
