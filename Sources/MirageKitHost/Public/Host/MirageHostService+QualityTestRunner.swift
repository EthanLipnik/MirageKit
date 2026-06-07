//
//  MirageHostService+QualityTestRunner.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Detached host quality-test stage runner.
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

#if os(macOS)
extension MirageHostService {
    nonisolated static func runQualityTestSession(
        request: MirageWire.QualityTestRequestMessage,
        payloadBytes: Int,
        via stream: any MirageQueuedUnreliableMediaStream,
        clientContext: ClientContext,
        hostCaptureCapability: MirageDiagnostics.MirageHostCaptureCapability?
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

            let completionMessage = MirageWire.QualityTestStageCompleteMessage(
                testID: request.testID,
                stageID: stage.id,
                probeKind: stage.probeKind,
                startedAtTimestampNs: metrics.startedAtTimestampNs,
                measurementEndedAtTimestampNs: metrics.measurementEndedAtTimestampNs,
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
        let benchmarkMessage = await makeQualityTestBenchmarkMessage(
            testID: request.testID,
            hostCaptureCapability: hostCaptureCapability
        )
        do {
            try await clientContext.send(.qualityTestResult, content: benchmarkMessage)
        } catch {
            MirageLogger.host("Quality test benchmark send failed: \(error)")
        }
    }

    nonisolated static func makeQualityTestBenchmarkMessage(
        testID: UUID,
        hostCaptureCapability: MirageDiagnostics.MirageHostCaptureCapability?
    ) async -> MirageWire.QualityTestBenchmarkMessage {
        let encodeMs: Double?
        do {
            encodeMs = try await MirageCodecBenchmark.runEncodeBenchmark()
        } catch {
            MirageLogger.error(.host, error: error, message: "Host quality-test encode benchmark failed: ")
            encodeMs = nil
        }

        return MirageWire.QualityTestBenchmarkMessage(
            testID: testID,
            encodeMs: encodeMs,
            hostCaptureCapability: hostCaptureCapability
        )
    }

    nonisolated static func runQualityTestTransferSession(
        request: MirageWire.QualityTestRequestMessage,
        transferByteCount: UInt64,
        transferEngine: MirageTransferEngine,
        clientContext: ClientContext,
        hostCaptureCapability: MirageDiagnostics.MirageHostCaptureCapability?
    ) async {
        do {
            let incomingTransfer = try await awaitQualityTestTransfer(
                testID: request.testID,
                transferEngine: transferEngine,
                timeout: .seconds(10)
            )
            guard incomingTransfer.offer.byteLength == transferByteCount else {
                try await incomingTransfer.decline()
                throw MirageCore.MirageError.protocolError(
                    "Connection test transfer size mismatch: expected \(transferByteCount), got \(incomingTransfer.offer.byteLength)"
                )
            }

            let sink = try await incomingTransfer.acceptDiscardingQualityTestTransfer()
            let terminalProgress = await MirageTransferProgress.terminalProgress(
                from: incomingTransfer.progressEvents
            )
            guard terminalProgress?.state == .completed else {
                throw MirageCore.MirageError.protocolError(
                    "Connection test transfer did not complete"
                )
            }

            let metrics = await sink.metrics()
            let bytesWritten = Int(clamping: metrics.bytesWritten)
            let completionMessage = MirageWire.QualityTestStageCompleteMessage(
                testID: request.testID,
                stageID: MirageQualityTestTransfer.stageID,
                probeKind: .transport,
                startedAtTimestampNs: metrics.startedAtTimestampNs,
                measurementEndedAtTimestampNs: metrics.completedAtTimestampNs,
                sentPacketCount: bytesWritten > 0 ? 1 : 0,
                sentPayloadBytes: bytesWritten,
                deliveryWindowMissed: false
            )
            try await clientContext.send(.qualityTestStageComplete, content: completionMessage)

            let benchmarkMessage = MirageWire.QualityTestBenchmarkMessage(
                testID: request.testID,
                encodeMs: nil,
                hostCaptureCapability: hostCaptureCapability
            )
            try await clientContext.send(.qualityTestResult, content: benchmarkMessage)

            let durationSeconds = Double(metrics.durationMs) / 1000.0
            let throughputMbps = durationSeconds > 0
                ? (Double(metrics.bytesWritten) * 8.0) / durationSeconds / 1_000_000.0
                : 0
            MirageLogger.host(
                "Quality test object transfer completed bytes=\(metrics.bytesWritten) durationMs=\(metrics.durationMs) throughput \(throughputMbps.formatted(.number.precision(.fractionLength(1)))) Mbps"
            )
        } catch is CancellationError {
            MirageLogger.host("Quality test object transfer cancelled")
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Quality test object transfer failed: "
            )
        }
    }

    nonisolated private static func awaitQualityTestTransfer(
        testID: UUID,
        transferEngine: MirageTransferEngine,
        timeout: Duration
    ) async throws -> MirageIncomingTransfer {
        try await withThrowingTaskGroup(of: MirageIncomingTransfer.self) { group in
            group.addTask {
                for await transfer in transferEngine.incomingTransfers {
                    guard MirageQualityTestTransfer.isMatchingTransfer(
                        offer: transfer.offer,
                        testID: testID
                    ) else {
                        continue
                    }
                    return transfer
                }
                throw MirageCore.MirageError.protocolError(
                    "Connection test transfer stream closed before an offer arrived."
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MirageCore.MirageError.protocolError(
                    "Timed out waiting for connection test transfer offer."
                )
            }

            let transfer = try await group.next() ?? {
                throw MirageCore.MirageError.protocolError(
                    "Connection test transfer wait ended unexpectedly."
                )
            }()
            group.cancelAll()
            return transfer
        }
    }

    nonisolated static func sendQualityTestStage(
        _ stage: MirageDiagnostics.MirageQualityTestPlan.Stage,
        testID: UUID,
        payloadBytes: Int,
        via stream: any MirageQueuedUnreliableMediaStream
    ) async -> QualityTestStageSendMetrics? {
        let payloadLength = UInt16(clamping: payloadBytes)
        let payload = qualityTestPayload(testID: testID, stageID: stage.id, payloadBytes: payloadBytes)
        let packetBytes = payloadBytes + MirageWire.mirageQualityTestHeaderSize
        let queueProfile = qualityTestQueueProfile(for: stage.probeKind)
        let stageSendState = QualityTestStageSendState(queueProfile: queueProfile)
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
                do {
                    try await Task.sleep(for: .milliseconds(sleepMs))
                } catch {
                    return false
                }
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
            let header = MirageWire.QualityTestPacketHeader(
                testID: testID,
                stageID: UInt16(stage.id),
                sequenceNumber: sequence,
                timestampNs: timestampNs,
                payloadLength: payloadLength
            )
            var packet = header.serialize()
            packet.append(payload)
            stream.sendUnreliableQueued(packet, profile: queueProfile) { error in
                stageSendState.completePacket(packetBytes: packetBytes, error: error)
            }
            sequence &+= 1
            stagePacketCount += 1
            stagePayloadBytes += payloadBytes
            return true
        }

        MirageLogger.host(
            "Quality test stage \(stage.id): kind \(stage.probeKind.rawValue), target \(mirageFormattedMegabitRate(stage.targetBitrateBps)), duration \(stage.durationMs)ms, payload \(payloadBytes)B"
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
                    do {
                        try await Task.sleep(for: .seconds(tickInterval))
                    } catch {
                        break
                    }
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
                    do {
                        try await Task.sleep(for: .milliseconds(1))
                    } catch {
                        return nil
                    }
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
            if stageSendState.outstandingPacketCount == 0 {
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                return nil
            }
        }

        let outstandingPacketsAfterSettle = stageSendState.outstandingPacketCount
        let deliveryWindowMissed = qualityTestMissedDeliveryWindow(
            targetBitrateBps: stage.targetBitrateBps,
            measurementDurationMs: stage.durationMs,
            payloadBytes: payloadBytes,
            packetBytes: packetBytes,
            sentPayloadBytes: stagePayloadBytes,
            encounteredEnqueueBackpressure: encounteredEnqueueBackpressure,
            outstandingPacketsAfterSettle: outstandingPacketsAfterSettle
        )
        if deliveryWindowMissed, outstandingPacketsAfterSettle > 0 {
            await stream.resetQueuedUnreliableSends(profile: queueProfile)
        }

        if let stageSendErrorDescription = stageSendState.errorDescription {
            MirageLogger.host(
                "Quality test stage \(stage.id) completed with queued send error: \(stageSendErrorDescription)"
            )
        }

        let measurementDurationSeconds = max(0.001, Double(stage.durationMs) / 1000.0)
        let sentMbps = (Double(stagePayloadBytes) * 8.0) / measurementDurationSeconds / 1_000_000.0
        MirageLogger.host(
            "Quality test stage \(stage.id) sent \(stagePacketCount) packets, \(stagePayloadBytes)B payload over \(stage.durationMs)ms, payload throughput \(sentMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, deliveryWindowMissed=\(deliveryWindowMissed), outstandingAfterSettle=\(outstandingPacketsAfterSettle)"
        )

        return QualityTestStageSendMetrics(
            startedAtTimestampNs: startedAtTimestampNs,
            measurementEndedAtTimestampNs: measurementEndedAtTimestampNs,
            sentPacketCount: stagePacketCount,
            sentPayloadBytes: stagePayloadBytes,
            deliveryWindowMissed: deliveryWindowMissed
        )
    }

    nonisolated static func qualityTestPayload(
        testID: UUID,
        stageID: Int,
        payloadBytes: Int
    ) -> Data {
        guard payloadBytes > 0 else { return Data() }
        var seed = qualityTestPayloadSeed(testID: testID, stageID: stageID)
        var bytes = [UInt8](repeating: 0, count: payloadBytes)
        var randomWord: UInt64 = 0
        var remainingWordBytes = 0
        for index in bytes.indices {
            if remainingWordBytes == 0 {
                seed = qualityTestPayloadNextWord(seed)
                randomWord = seed
                remainingWordBytes = MemoryLayout<UInt64>.size
            }
            bytes[index] = UInt8(truncatingIfNeeded: randomWord)
            randomWord >>= 8
            remainingWordBytes -= 1
        }
        return Data(bytes)
    }

    private nonisolated static func qualityTestPayloadSeed(testID: UUID, stageID: Int) -> UInt64 {
        var seed: UInt64 = 0xcbf2_9ce4_8422_2325 ^ UInt64(truncatingIfNeeded: stageID)
        var uuid = testID.uuid
        withUnsafeBytes(of: &uuid) { rawBytes in
            for byte in rawBytes {
                seed ^= UInt64(byte)
                seed &*= 0x0000_0100_0000_01b3
            }
        }
        return seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed
    }

    private nonisolated static func qualityTestPayloadNextWord(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
#endif
