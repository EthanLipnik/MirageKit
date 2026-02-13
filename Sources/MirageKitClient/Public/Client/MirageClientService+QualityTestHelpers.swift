//
//  MirageClientService+QualityTestHelpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/4/26.
//
//  Helper routines for automatic quality tests.
//

import Foundation
import Network
import MirageKit

@MainActor
extension MirageClientService {
    nonisolated func handleQualityTestPacket(_ header: QualityTestPacketHeader, data: Data) {
        qualityTestLock.lock()
        let accumulator = qualityTestAccumulatorStorage
        let activeTestID = qualityTestActiveTestIDStorage
        qualityTestLock.unlock()

        guard let accumulator, activeTestID == header.testID else { return }
        let payloadBytes = min(Int(header.payloadLength), max(0, data.count - mirageQualityTestHeaderSize))
        accumulator.record(header: header, payloadBytes: payloadBytes)
    }

    func measureRTT() async throws -> Double {
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

    func sendPingAndAwaitPong() async throws {
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
                if let pingContinuation {
                    pingContinuation.resume(throwing: MirageError.protocolError("Ping timed out"))
                    self.pingContinuation = nil
                }
            }
        }
    }

    func awaitQualityTestResult(testID: UUID, timeout: Duration) async -> QualityTestResultMessage? {
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
                guard let continuation = qualityTestResultContinuation else { return }
                continuation.resume(returning: nil)
                qualityTestResultContinuation = nil
                qualityTestPendingTestID = nil
            }
        }
    }

    func sendQualityTestRegistration() async throws {
        guard let udpConnection else {
            throw MirageError.protocolError("No UDP connection")
        }
        guard let mediaSecurityContext else {
            throw MirageError.protocolError("Missing media security context")
        }

        var data = Data()
        data.append(contentsOf: [0x4D, 0x49, 0x52, 0x51])
        withUnsafeBytes(of: deviceID.uuid) { data.append(contentsOf: $0) }
        data.append(mediaSecurityContext.udpRegistrationToken)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            udpConnection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }
        MirageLogger.client(
            "Quality-test UDP registration sent (tokenBytes=\(mediaSecurityContext.udpRegistrationToken.count))"
        )
    }

    func runDecodeBenchmark() async throws -> MirageCodecBenchmarkStore.Record {
        let store = MirageCodecBenchmarkStore()
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

    func runQualityTestStage(
        testID: UUID,
        stageID: Int,
        targetBitrateBps: Int,
        durationMs: Int,
        payloadBytes: Int,
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
            "Quality test stage \(stageID) start: target \(targetMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, duration \(durationMs)ms, payload \(payloadBytes)B"
        )

        let request = QualityTestRequestMessage(
            testID: testID,
            plan: plan,
            payloadBytes: payloadBytes
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

    func stageIsStable(
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

    nonisolated func setQualityTestAccumulator(_ accumulator: QualityTestAccumulator, testID: UUID) {
        qualityTestLock.lock()
        qualityTestAccumulatorStorage = accumulator
        qualityTestActiveTestIDStorage = testID
        qualityTestLock.unlock()
    }

    func clearQualityTestAccumulator() {
        qualityTestLock.lock()
        qualityTestAccumulatorStorage = nil
        qualityTestActiveTestIDStorage = nil
        qualityTestLock.unlock()
    }
}

func describeQualityTestNetworkPath(_ path: NWPath) -> String {
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
