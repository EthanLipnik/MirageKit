//
//  MirageHostService+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Host-side quality test handling.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
private final class QualityTestStageSendState: @unchecked Sendable {
    private let lock = NSLock()
    private var outstandingPackets = 0
    private var outstandingBytes = 0
    private var sendErrorDescription: String?

    func tryReserve(packetBytes: Int) -> Bool {
        lock.lock()
        let canReserve = MirageHostService.qualityTestCanEnqueuePacket(
            outstandingPackets: outstandingPackets,
            outstandingBytes: outstandingBytes,
            packetBytes: packetBytes
        )
        if canReserve {
            outstandingPackets += 1
            outstandingBytes += packetBytes
        }
        lock.unlock()
        return canReserve
    }

    func completePacket(packetBytes: Int, error: Error?) {
        lock.lock()
        outstandingPackets = max(0, outstandingPackets - 1)
        outstandingBytes = max(0, outstandingBytes - packetBytes)
        if sendErrorDescription == nil, let error {
            sendErrorDescription = String(describing: error)
        }
        lock.unlock()
    }

    func errorDescription() -> String? {
        lock.lock()
        let description = sendErrorDescription
        lock.unlock()
        return description
    }

    func snapshot() -> (outstandingPackets: Int, outstandingBytes: Int) {
        lock.lock()
        let snapshot = (outstandingPackets, outstandingBytes)
        lock.unlock()
        return snapshot
    }
}

private struct QualityTestPacketPacer {
    let targetRateBps: Int
    private var tokensBytes: Double = 0
    private var lastRefillTime: CFAbsoluteTime = 0

    init(targetRateBps: Int) {
        self.targetRateBps = targetRateBps
    }

    mutating func paceNextPacket(
        packetBytes: Int,
        isKeyframeBurst: Bool,
        totalFragments: Int
    ) async {
        guard let parameters = StreamPacketSender.packetPacingParameters(
            targetRateBps: targetRateBps,
            packetBytes: packetBytes,
            isKeyframeBurst: isKeyframeBurst,
            totalFragments: totalFragments,
            pacingOverride: nil
        ) else {
            return
        }

        let initialNow = CFAbsoluteTimeGetCurrent()
        refill(
            now: initialNow,
            bytesPerSecond: parameters.bytesPerSecond,
            burstBytes: parameters.burstBytes
        )
        let sleepMs = StreamPacketSender.packetPacerSleepMilliseconds(
            tokensBeforeSend: tokensBytes,
            packetBytes: packetBytes,
            bytesPerMillisecond: parameters.bytesPerSecond / 1000.0
        )
        if sleepMs > 0 {
            try? await Task.sleep(for: .milliseconds(sleepMs))
            refill(
                now: CFAbsoluteTimeGetCurrent(),
                bytesPerSecond: parameters.bytesPerSecond,
                burstBytes: parameters.burstBytes
            )
        }

        tokensBytes -= Double(packetBytes)
    }

    private mutating func refill(
        now: CFAbsoluteTime,
        bytesPerSecond: Double,
        burstBytes: Double
    ) {
        if lastRefillTime == 0 {
            lastRefillTime = now
            tokensBytes = burstBytes
            return
        }

        let elapsed = max(0.0, now - lastRefillTime)
        lastRefillTime = now
        tokensBytes = min(
            burstBytes,
            max(-burstBytes, tokensBytes + elapsed * bytesPerSecond)
        )
    }
}

private struct QualityTestStageSendMetrics {
    let startedAtTimestampNs: UInt64
    let measurementEndedAtTimestampNs: UInt64
    let completedAtTimestampNs: UInt64
    let sentPacketCount: Int
    let sentPayloadBytes: Int
    let deliveryWindowMissed: Bool
}

@MainActor
extension MirageHostService {
    nonisolated private static let qualityTestQueueProfile: LoomQueuedUnreliableSendProfile = .throughputProbe
    nonisolated private static let qualityTestQueueLimits = qualityTestQueueProfile.recommendedLimits
    nonisolated private static let qualityTestMinimumTickIntervalSeconds = 0.00025
    nonisolated private static let qualityTestMaximumBurstPackets = 4_096
    nonisolated private static let qualityTestReplayFrameRate = 60
    nonisolated private static let qualityTestReplayKeyframeMultiplier = 8.0
    nonisolated private static let qualityTestDeliveryFloor = 0.90

    nonisolated static func qualityTestCanEnqueuePacket(
        outstandingPackets: Int,
        outstandingBytes: Int,
        packetBytes: Int
    ) -> Bool {
        guard packetBytes > 0 else { return true }
        if outstandingPackets >= qualityTestQueueLimits.maxOutstandingPackets {
            return false
        }
        if outstandingPackets == 0 {
            return true
        }
        return outstandingBytes + packetBytes <= qualityTestQueueLimits.maxOutstandingBytes
    }

    nonisolated static func qualityTestMissedDeliveryWindow(
        targetBitrateBps: Int,
        measurementDurationMs: Int,
        payloadBytes: Int,
        packetBytes: Int,
        sentPayloadBytes: Int,
        encounteredEnqueueBackpressure: Bool,
        outstandingPacketsAfterSettle: Int
    ) -> Bool {
        if encounteredEnqueueBackpressure || outstandingPacketsAfterSettle > 0 {
            return true
        }
        guard
            targetBitrateBps > 0,
            measurementDurationMs > 0,
            payloadBytes > 0,
            packetBytes > 0
        else {
            return false
        }

        let payloadRatio = Double(payloadBytes) / Double(packetBytes)
        let expectedPayloadBps = Double(targetBitrateBps) * payloadRatio
        let deliveredPayloadBps = Double(sentPayloadBytes * 8) / (Double(measurementDurationMs) / 1000.0)
        return deliveredPayloadBps < expectedPayloadBps * qualityTestDeliveryFloor
    }

    nonisolated static func qualityTestShouldTerminateSweep(
        stopAfterFirstBreach: Bool,
        deliveryWindowMissed: Bool
    ) -> Bool {
        stopAfterFirstBreach && deliveryWindowMissed
    }

    func handleQualityTestRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        guard let request = try? message.decode(QualityTestRequestMessage.self) else {
            MirageLogger.host("Failed to decode quality test request")
            return
        }

        let client = clientContext.client
        await cancelQualityTest(for: client.id, reason: "superseded by new quality-test request")
        qualityTestSessionTokensByClientID[client.id] = UUID()
        qualityTestIDsByClientID[client.id] = request.testID
        let sessionToken = qualityTestSessionTokensByClientID[client.id] ?? UUID()

        let pathKind = clientContext.pathSnapshot.map { MirageNetworkPathClassifier.classify($0).kind }
        let acceptedMediaMaxPacketSize = mirageNegotiatedMediaMaxPacketSize(
            requested: request.mediaMaxPacketSize,
            pathKind: pathKind
        )
        let payloadBytes = min(
            request.payloadBytes,
            miragePayloadSize(maxPacketSize: acceptedMediaMaxPacketSize)
        )

        let qualityStream: LoomMultiplexedStream
        do {
            qualityStream = try await clientContext.controlChannel.session.openStream(
                label: "quality-test/\(request.testID)"
            )
        } catch {
            MirageLogger.host("Quality test skipped - failed to open Loom stream for client \(client.name): \(error)")
            return
        }
        qualityTestStreamsByClientID[client.id] = qualityStream

        let task = Task.detached(priority: .userInitiated) { [weak self, clientContext, request, qualityStream] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.qualityTestSessionTokensByClientID[client.id] == sessionToken else { return }
                    self.qualityTestTasksByClientID.removeValue(forKey: client.id)
                    self.qualityTestSessionTokensByClientID.removeValue(forKey: client.id)
                    self.qualityTestIDsByClientID.removeValue(forKey: client.id)
                    await self.closeQualityTestStream(for: client.id)
                }
            }

            await Self.runQualityTestSession(
                request: request,
                payloadBytes: payloadBytes,
                via: qualityStream,
                clientContext: clientContext
            )
        }
        qualityTestTasksByClientID[client.id] = task
    }

    func closeQualityTestStream(
        for clientID: UUID,
        resetQueuedSends: Bool = false
    ) async {
        guard let stream = qualityTestStreamsByClientID.removeValue(forKey: clientID) else {
            return
        }
        if resetQueuedSends {
            await stream.resetQueuedUnreliableSends(profile: Self.qualityTestQueueProfile)
        }
        try? await stream.close()
    }

    func handleQualityTestCancel(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        guard let request = try? message.decode(QualityTestCancelMessage.self) else {
            MirageLogger.host("Failed to decode quality test cancellation request")
            return
        }

        _ = await cancelQualityTest(
            for: clientContext.client.id,
            expectedTestID: request.testID,
            reason: "client requested cancellation"
        )
    }

    @discardableResult
    func cancelQualityTest(
        for clientID: UUID,
        expectedTestID: UUID? = nil,
        reason: String
    ) async -> Bool {
        if let expectedTestID,
           let activeTestID = qualityTestIDsByClientID[clientID],
           activeTestID != expectedTestID {
            MirageLogger.host(
                "Ignoring stale quality-test cancellation for client \(clientID) expected=\(expectedTestID.uuidString) active=\(activeTestID.uuidString)"
            )
            return false
        }

        let activeTestID = qualityTestIDsByClientID.removeValue(forKey: clientID)
        let sessionToken = qualityTestSessionTokensByClientID.removeValue(forKey: clientID)
        let task = qualityTestTasksByClientID.removeValue(forKey: clientID)
        let hasActiveStream = qualityTestStreamsByClientID[clientID] != nil

        guard activeTestID != nil || sessionToken != nil || task != nil || hasActiveStream else {
            return false
        }

        task?.cancel()
        await closeQualityTestStream(for: clientID, resetQueuedSends: true)

        let testDescription = activeTestID?.uuidString ?? "unknown"
        MirageLogger.host(
            "Cancelled quality test for client \(clientID) testID=\(testDescription) reason=\(reason)"
        )
        return true
    }

    nonisolated private static func runQualityTestSession(
        request: QualityTestRequestMessage,
        payloadBytes: Int,
        via stream: LoomMultiplexedStream,
        clientContext: ClientContext
    ) async {
        for stage in request.plan.stages {
            if Task.isCancelled { return }
            guard let metrics = await sendQualityTestStage(
                stage,
                testID: request.testID,
                payloadBytes: payloadBytes,
                via: stream
            ) else {
                return
            }

            let completionMessage = QualityTestStageCompleteMessage(
                testID: request.testID,
                stageID: stage.id,
                probeKind: stage.probeKind,
                targetBitrateBps: stage.targetBitrateBps,
                configuredDurationMs: stage.durationMs,
                startedAtTimestampNs: metrics.startedAtTimestampNs,
                measurementEndedAtTimestampNs: metrics.measurementEndedAtTimestampNs,
                completedAtTimestampNs: metrics.completedAtTimestampNs,
                sentPacketCount: metrics.sentPacketCount,
                sentPayloadBytes: metrics.sentPayloadBytes,
                deliveryWindowMissed: metrics.deliveryWindowMissed
            )
            do {
                try await clientContext.send(.qualityTestStageComplete, content: completionMessage)
            } catch {
                MirageLogger.host("Quality test stage \(stage.id) failed to send completion metadata: \(error)")
                return
            }

            if qualityTestShouldTerminateSweep(
                stopAfterFirstBreach: request.stopAfterFirstBreach,
                deliveryWindowMissed: metrics.deliveryWindowMissed
            ) {
                MirageLogger.host(
                    "Quality test stopped after overload boundary at stage \(stage.id)"
                )
                break
            }
        }

        if Task.isCancelled { return }
        let benchmarkMessage = await makeQualityTestBenchmarkMessage(testID: request.testID)
        do {
            try await clientContext.send(.qualityTestResult, content: benchmarkMessage)
        } catch {
            MirageLogger.host("Quality test benchmark send failed: \(error)")
        }
    }

    nonisolated private static func makeQualityTestBenchmarkMessage(
        testID: UUID
    ) async -> QualityTestBenchmarkMessage {
        let store = MirageCodecBenchmarkStore()
        let encodeMs = try? await MirageCodecBenchmark.runEncodeBenchmark()
        let record = MirageCodecBenchmarkStore.Record(
            version: MirageCodecBenchmarkStore.currentVersion,
            benchmarkWidth: MirageCodecBenchmark.benchmarkWidth,
            benchmarkHeight: MirageCodecBenchmark.benchmarkHeight,
            benchmarkFrameRate: MirageCodecBenchmark.benchmarkFrameRate,
            hostEncodeMs: encodeMs,
            clientDecodeMs: nil,
            measuredAt: Date()
        )
        store.save(record)

        return QualityTestBenchmarkMessage(
            testID: testID,
            benchmarkWidth: record.benchmarkWidth,
            benchmarkHeight: record.benchmarkHeight,
            benchmarkFrameRate: record.benchmarkFrameRate,
            encodeMs: record.hostEncodeMs,
            benchmarkVersion: record.version
        )
    }

    nonisolated private static func sendQualityTestStage(
        _ stage: MirageQualityTestPlan.Stage,
        testID: UUID,
        payloadBytes: Int,
        via stream: LoomMultiplexedStream
    ) async -> QualityTestStageSendMetrics? {
        let payloadLength = UInt16(clamping: payloadBytes)
        let payload = Data(repeating: 0, count: payloadBytes)
        let packetBytes = payloadBytes + mirageQualityTestHeaderSize
        let stageSendState = QualityTestStageSendState()
        var sequence: UInt32 = 0
        var stagePacketCount = 0
        var stagePayloadBytes = 0
        let stageStart = CFAbsoluteTimeGetCurrent()
        let measurementDeadline = stageStart + (Double(stage.durationMs) / 1000.0)
        let settleDeadline = measurementDeadline + (Double(stage.settleGraceMs) / 1000.0)
        let startedAtTimestampNs = UInt64(stageStart * 1_000_000_000)
        let measurementEndedAtTimestampNs = UInt64(measurementDeadline * 1_000_000_000)
        var encounteredEnqueueBackpressure = false

        func sleepUntil(_ deadline: CFAbsoluteTime) async -> Bool {
            while CFAbsoluteTimeGetCurrent() < deadline {
                if Task.isCancelled { return false }
                let remainingMs = Int(ceil((deadline - CFAbsoluteTimeGetCurrent()) * 1000.0))
                let sleepMs = max(1, min(10, remainingMs))
                try? await Task.sleep(for: .milliseconds(sleepMs))
            }
            return true
        }

        func enqueuePacket(
            isKeyframeBurst: Bool,
            totalFragments: Int,
            pacer: inout QualityTestPacketPacer?
        ) async -> Bool {
            guard stageSendState.tryReserve(packetBytes: packetBytes) else {
                encounteredEnqueueBackpressure = true
                return false
            }
            if var localPacer = pacer {
                await localPacer.paceNextPacket(
                    packetBytes: packetBytes,
                    isKeyframeBurst: isKeyframeBurst,
                    totalFragments: totalFragments
                )
                pacer = localPacer
            }
            let timestampNs = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000_000)
            let header = QualityTestPacketHeader(
                testID: testID,
                stageID: UInt16(stage.id),
                sequenceNumber: sequence,
                timestampNs: timestampNs,
                payloadLength: payloadLength
            )
            var packet = header.serialize()
            packet.append(payload)
            stream.sendUnreliableQueued(packet, profile: qualityTestQueueProfile) { error in
                stageSendState.completePacket(packetBytes: packetBytes, error: error)
            }
            sequence &+= 1
            stagePacketCount += 1
            stagePayloadBytes += payloadBytes
            return true
        }

        let targetMbps = Double(stage.targetBitrateBps) / 1_000_000.0
        MirageLogger.host(
            "Quality test stage \(stage.id): kind \(stage.probeKind.rawValue), target \(targetMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, duration \(stage.durationMs)ms, payload \(payloadBytes)B"
        )

        switch stage.probeKind {
        case .transport:
            let durationSeconds = Double(stage.durationMs) / 1000.0
            let packetsPerSecond = packetBytes > 0
                ? (Double(stage.targetBitrateBps) / 8.0) / Double(packetBytes)
                : 0
            let baseInterval = packetsPerSecond > 0 ? 1.0 / packetsPerSecond : 0
            let tickInterval = baseInterval > 0
                ? max(baseInterval, qualityTestMinimumTickIntervalSeconds)
                : 0
            var packetBudget = 0.0
            var lastTickTime = stageStart

            while CFAbsoluteTimeGetCurrent() - stageStart < durationSeconds {
                if Task.isCancelled { return nil }
                guard packetsPerSecond > 0 else {
                    await Task.yield()
                    continue
                }

                let now = CFAbsoluteTimeGetCurrent()
                let delta = max(0, now - lastTickTime)
                lastTickTime = now
                packetBudget += packetsPerSecond * delta
                let sendCount = min(Int(packetBudget), qualityTestMaximumBurstPackets)
                if sendCount > 0 {
                    packetBudget -= Double(sendCount)
                    for _ in 0 ..< sendCount {
                        if CFAbsoluteTimeGetCurrent() >= measurementDeadline {
                            break
                        }
                        var noPacer: QualityTestPacketPacer?
                        if !(await enqueuePacket(
                            isKeyframeBurst: false,
                            totalFragments: sendCount,
                            pacer: &noPacer
                        )) {
                            break
                        }
                    }
                }

                if encounteredEnqueueBackpressure {
                    break
                }

                if tickInterval > 0 {
                    try? await Task.sleep(for: .seconds(tickInterval))
                } else {
                    await Task.yield()
                }
            }

        case .streamingReplay:
            let durationSeconds = Double(stage.durationMs) / 1000.0
            let frameRate = qualityTestReplayFrameRate
            let frameInterval = 1.0 / Double(frameRate)
            let frameCount = max(1, Int(ceil(durationSeconds * Double(frameRate))))
            let totalTargetPayloadBytes = max(
                Double(payloadBytes),
                Double(stage.targetBitrateBps) * durationSeconds / 8.0
            )
            let averageFramePayloadBytes = totalTargetPayloadBytes / Double(frameCount)
            let keyframePayloadBytes = min(
                totalTargetPayloadBytes * 0.25,
                max(Double(payloadBytes), averageFramePayloadBytes * qualityTestReplayKeyframeMultiplier)
            )
            let steadyFramePayloadBytes = frameCount > 1
                ? max(Double(payloadBytes), (totalTargetPayloadBytes - keyframePayloadBytes) / Double(frameCount - 1))
                : keyframePayloadBytes
            var pacer = QualityTestPacketPacer(targetRateBps: stage.targetBitrateBps)

            for frameIndex in 0 ..< frameCount {
                if Task.isCancelled { return nil }

                let scheduledTime = stageStart + (Double(frameIndex) * frameInterval)
                while CFAbsoluteTimeGetCurrent() < scheduledTime {
                    if Task.isCancelled { return nil }
                    try? await Task.sleep(for: .milliseconds(1))
                }

                let framePayloadBytes = frameIndex == 0 ? keyframePayloadBytes : steadyFramePayloadBytes
                let fragmentCount = max(1, Int(ceil(framePayloadBytes / Double(payloadBytes))))
                for _ in 0 ..< fragmentCount {
                    if CFAbsoluteTimeGetCurrent() >= measurementDeadline {
                        break
                    }
                    var localPacer: QualityTestPacketPacer? = pacer
                    guard await enqueuePacket(
                        isKeyframeBurst: frameIndex == 0,
                        totalFragments: fragmentCount,
                        pacer: &localPacer
                    ) else {
                        break
                    }
                    if let localPacer {
                        pacer = localPacer
                    }
                }
                if encounteredEnqueueBackpressure {
                    break
                }
            }
        }

        guard await sleepUntil(measurementDeadline) else { return nil }

        while CFAbsoluteTimeGetCurrent() < settleDeadline {
            if Task.isCancelled { return nil }
            if stageSendState.snapshot().outstandingPackets == 0 {
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }

        let outstandingSnapshot = stageSendState.snapshot()
        let deliveryWindowMissed = qualityTestMissedDeliveryWindow(
            targetBitrateBps: stage.targetBitrateBps,
            measurementDurationMs: stage.durationMs,
            payloadBytes: payloadBytes,
            packetBytes: packetBytes,
            sentPayloadBytes: stagePayloadBytes,
            encounteredEnqueueBackpressure: encounteredEnqueueBackpressure,
            outstandingPacketsAfterSettle: outstandingSnapshot.outstandingPackets
        )
        if deliveryWindowMissed, outstandingSnapshot.outstandingPackets > 0 {
            await stream.resetQueuedUnreliableSends(profile: qualityTestQueueProfile)
        }

        if let stageSendErrorDescription = stageSendState.errorDescription() {
            MirageLogger.host(
                "Quality test stage \(stage.id) completed with queued send error: \(stageSendErrorDescription)"
            )
        }

        let completedAtTimestampNs = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000_000)
        let measurementDurationSeconds = max(0.001, Double(stage.durationMs) / 1000.0)
        let sentMbps = (Double(stagePayloadBytes) * 8.0) / measurementDurationSeconds / 1_000_000.0
        MirageLogger.host(
            "Quality test stage \(stage.id) sent \(stagePacketCount) packets, \(stagePayloadBytes)B payload over \(stage.durationMs)ms, payload throughput \(sentMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, deliveryWindowMissed=\(deliveryWindowMissed), outstandingAfterSettle=\(outstandingSnapshot.outstandingPackets)"
        )

        return QualityTestStageSendMetrics(
            startedAtTimestampNs: startedAtTimestampNs,
            measurementEndedAtTimestampNs: measurementEndedAtTimestampNs,
            completedAtTimestampNs: completedAtTimestampNs,
            sentPacketCount: stagePacketCount,
            sentPayloadBytes: stagePayloadBytes,
            deliveryWindowMissed: deliveryWindowMissed
        )
    }
}
#endif
