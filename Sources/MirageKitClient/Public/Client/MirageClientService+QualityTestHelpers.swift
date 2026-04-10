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
import Network

@MainActor
extension MirageClientService {
    struct PingWaiterRegistration {
        let requestID: UInt64
        let startedNewRequest: Bool
    }

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
        let context = fastPathState.qualityTestContext()
        let accumulator = context.accumulator
        let activeTestID = context.testID
        guard let accumulator, activeTestID == header.testID else { return }
        let payloadBytes = min(Int(header.payloadLength), max(0, data.count - mirageQualityTestHeaderSize))
        accumulator.record(header: header, payloadBytes: payloadBytes)
    }

    func measureRTT(
        sendPing: (@MainActor @Sendable () async throws -> Void)? = nil
    ) async throws -> Double {
        var samples: [Double] = []

        for _ in 0 ..< 3 {
            let start = CFAbsoluteTimeGetCurrent()
            try await sendPingAndAwaitPong(sendPing: sendPing)
            let delta = (CFAbsoluteTimeGetCurrent() - start) * 1000
            samples.append(delta)
        }

        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    func sendPingAndAwaitPong(
        timeout: Duration = .seconds(5),
        sendPing: (@MainActor @Sendable () async throws -> Void)? = nil
    ) async throws {
        guard case .connected = connectionState else {
            throw MirageError.protocolError("Not connected")
        }
        let message = ControlMessage(type: .ping)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let registration = registerPingWaiter(continuation, timeout: timeout)
            guard registration.startedNewRequest else { return }
            Task { @MainActor [weak self] in
                do {
                    if let sendPing {
                        try await sendPing()
                    } else {
                        try await self?.sendControlMessage(message)
                    }
                } catch {
                    self?.completePingRequest(
                        expectedRequestID: registration.requestID,
                        result: .failure(error)
                    )
                }
            }
        }
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
            try? await sendControlMessage(
                .qualityTestCancel,
                content: QualityTestCancelMessage(testID: testID)
            )
        }

        qualityTestPendingTestID = nil
        qualityTestBenchmarkTimeoutTask?.cancel()
        qualityTestBenchmarkTimeoutTask = nil
        qualityTestStageCompletionTimeoutTask?.cancel()
        qualityTestStageCompletionTimeoutTask = nil
        qualityTestStageCompletionBuffer.removeAll()
        clearQualityTestAccumulator()

        failActivePingRequests(with: CancellationError())

        completeQualityTestBenchmarkWaiter(result: nil)
        completeQualityTestStageCompletionWaiter(result: nil)

        if let task = qualityTestStreamReceiveTasks.removeValue(forKey: testID) {
            task.cancel()
        }
        activeMediaStreams.removeValue(forKey: "quality-test/\(testID.uuidString)")
    }

    func awaitQualityTestBenchmark(
        testID: UUID,
        timeout: Duration
    ) async -> QualityTestBenchmarkMessage? {
        if let pending = qualityTestPendingTestID, pending != testID {
            completeQualityTestBenchmarkWaiter(result: nil)
            completeQualityTestStageCompletionWaiter(result: nil)
            qualityTestStageCompletionBuffer.removeAll()
        }

        qualityTestBenchmarkWaiterID &+= 1
        let waiterID = qualityTestBenchmarkWaiterID
        qualityTestPendingTestID = testID

        return await withCheckedContinuation { continuation in
            qualityTestBenchmarkContinuation = continuation
            qualityTestBenchmarkTimeoutTask?.cancel()
            qualityTestBenchmarkTimeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self.completeQualityTestBenchmarkWaiter(
                    expectedWaiterID: waiterID,
                    expectedTestID: testID,
                    result: nil
                )
            }
        }
    }

    func awaitQualityTestStageCompletion(
        testID: UUID,
        stageID: Int,
        timeout: Duration
    ) async -> QualityTestStageCompleteMessage? {
        if let pending = qualityTestPendingTestID, pending != testID {
            completeQualityTestBenchmarkWaiter(result: nil)
            completeQualityTestStageCompletionWaiter(result: nil)
            qualityTestStageCompletionBuffer.removeAll()
        }

        qualityTestPendingTestID = testID
        if let bufferedIndex = qualityTestStageCompletionBuffer.firstIndex(where: { completion in
            completion.testID == testID && completion.stageID == stageID
        }) {
            return qualityTestStageCompletionBuffer.remove(at: bufferedIndex)
        }

        qualityTestStageCompletionWaiterID &+= 1
        let waiterID = qualityTestStageCompletionWaiterID
        return await withCheckedContinuation { continuation in
            qualityTestStageCompletionContinuation = continuation
            qualityTestStageCompletionTimeoutTask?.cancel()
            qualityTestStageCompletionTimeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self.completeQualityTestStageCompletionWaiter(
                    expectedWaiterID: waiterID,
                    expectedTestID: testID,
                    result: nil
                )
            }
        }
    }

    func sendQualityTestRegistration() async throws {
        MirageLogger.client("Quality-test registration skipped (media via Loom session)")
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
        setQualityTestAccumulator(accumulator, testID: testID)
        qualityTestPendingTestID = testID
        qualityTestStageCompletionBuffer.removeAll()
        defer {
            clearQualityTestAccumulator()
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
            let timeout = Duration.milliseconds(
                Self.qualityTestStageCompletionTimeoutMs(for: stage)
            )
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
                "Quality test stage \(stage.id) result kind=\(stage.probeKind.rawValue) target \((Double(stage.targetBitrateBps) / 1_000_000.0).formatted(.number.precision(.fractionLength(1)))) Mbps, sent \(sentMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, received \(throughputMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, loss \(lossText)%, packets \(stageResult.receivedPacketCount)/\(stageResult.sentPacketCount)"
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
            let stageStable = stageIsStable(
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
        targetBitrateBps: Int,
        durationMs: Int,
        payloadBytes: Int,
        mediaMaxPacketSize: Int
    ) async throws -> MirageQualityTestSummary.StageResult {
        let stage = MirageQualityTestPlan.Stage(
            id: stageID,
            probeKind: .transport,
            targetBitrateBps: targetBitrateBps,
            durationMs: durationMs
        )
        let targetMbps = Double(targetBitrateBps) / 1_000_000.0
        MirageLogger.client(
            "Quality test stage \(stageID) start: target \(targetMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, duration \(durationMs)ms, payload \(payloadBytes)B"
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

    func stageIsStable(
        _ stage: MirageQualityTestSummary.StageResult,
        targetBitrate: Int,
        payloadBytes: Int,
        throughputFloor: Double?,
        lossCeiling: Double,
        requiresLossBelowCeiling: Bool = false
    ) -> Bool {
        Self.qualityTestStageIsStable(
            stage,
            targetBitrate: targetBitrate,
            payloadBytes: payloadBytes,
            throughputFloor: throughputFloor,
            lossCeiling: lossCeiling,
            requiresLossBelowCeiling: requiresLossBelowCeiling
        )
    }

    nonisolated func setQualityTestAccumulator(_ accumulator: QualityTestAccumulator, testID: UUID) {
        fastPathState.setQualityTestAccumulator(accumulator, testID: testID)
    }

    nonisolated static func qualityTestStageCompletionTimeoutMs(
        for stage: MirageQualityTestPlan.Stage
    ) -> Int {
        stage.totalCompletionBudgetMs + qualityTestControlMessageMarginMs
    }

    func clearQualityTestAccumulator() {
        fastPathState.clearQualityTestAccumulator()
    }

    func registerPingWaiter(
        _ continuation: CheckedContinuation<Void, Error>,
        timeout: Duration = .seconds(5)
    ) -> PingWaiterRegistration {
        pingContinuations.append(continuation)
        if pingContinuations.count > 1 {
            return PingWaiterRegistration(
                requestID: pingRequestID,
                startedNewRequest: false
            )
        }

        pingRequestID &+= 1
        let requestID = pingRequestID
        pingTimeoutTask?.cancel()
        pingTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self.completePingRequest(
                expectedRequestID: requestID,
                result: .failure(MirageError.protocolError("Ping timed out"))
            )
        }

        return PingWaiterRegistration(
            requestID: requestID,
            startedNewRequest: true
        )
    }

    func failActivePingRequests(with error: Error) {
        guard !pingContinuations.isEmpty else {
            pingTimeoutTask?.cancel()
            pingTimeoutTask = nil
            return
        }
        completePingRequest(
            expectedRequestID: pingRequestID,
            result: .failure(error)
        )
    }

    func completePingRequest(
        expectedRequestID: UInt64,
        result: Result<Void, Error>
    ) {
        guard pingRequestID == expectedRequestID, !pingContinuations.isEmpty else { return }
        let continuations = pingContinuations
        pingContinuations.removeAll(keepingCapacity: false)
        pingTimeoutTask?.cancel()
        pingTimeoutTask = nil
        for continuation in continuations {
            switch result {
            case .success:
                continuation.resume()
            case let .failure(error):
                continuation.resume(throwing: error)
            }
        }
    }

    func completeQualityTestBenchmarkWaiter(
        expectedWaiterID: UInt64? = nil,
        expectedTestID: UUID? = nil,
        result: QualityTestBenchmarkMessage?
    ) {
        if let expectedWaiterID, qualityTestBenchmarkWaiterID != expectedWaiterID { return }
        if let expectedTestID, qualityTestPendingTestID != expectedTestID { return }
        qualityTestBenchmarkTimeoutTask?.cancel()
        qualityTestBenchmarkTimeoutTask = nil
        guard let continuation = qualityTestBenchmarkContinuation else { return }
        qualityTestBenchmarkContinuation = nil
        continuation.resume(returning: result)
    }

    func completeQualityTestStageCompletionWaiter(
        expectedWaiterID: UInt64? = nil,
        expectedTestID: UUID? = nil,
        result: QualityTestStageCompleteMessage?
    ) {
        if let expectedWaiterID, qualityTestStageCompletionWaiterID != expectedWaiterID { return }
        if let expectedTestID, qualityTestPendingTestID != expectedTestID { return }
        qualityTestStageCompletionTimeoutTask?.cancel()
        qualityTestStageCompletionTimeoutTask = nil
        guard let continuation = qualityTestStageCompletionContinuation else { return }
        qualityTestStageCompletionContinuation = nil
        continuation.resume(returning: result)
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
