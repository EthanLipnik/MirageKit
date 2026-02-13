//
//  MirageHostService+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Host-side quality test handling.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func handleQualityTestRequest(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        connection: NWConnection
    ) async {
        guard let request = try? message.decode(QualityTestRequestMessage.self) else {
            MirageLogger.host("Failed to decode quality test request")
            return
        }

        let lastBenchmarkID = qualityTestBenchmarkIDsByClientID[client.id]
        if lastBenchmarkID != request.testID {
            qualityTestBenchmarkIDsByClientID[client.id] = request.testID
            Task.detached { [weak self] in
                await self?.sendCodecBenchmarkResult(testID: request.testID, to: connection)
            }
        }

        guard let udpConnection = qualityTestConnectionsByClientID[client.id] else {
            MirageLogger.host("Quality test skipped - no UDP registration for client \(client.name)")
            return
        }

        if let task = qualityTestTasksByClientID[client.id] {
            task.cancel()
        }

        let task = Task.detached(priority: .userInitiated) { [request, udpConnection] in
            await Self.sendQualityTestPackets(
                to: udpConnection,
                testID: request.testID,
                plan: request.plan,
                payloadBytes: request.payloadBytes
            )
        }
        qualityTestTasksByClientID[client.id] = task
    }

    private func sendCodecBenchmarkResult(testID: UUID, to connection: NWConnection) async {
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

        let result = QualityTestResultMessage(
            testID: testID,
            benchmarkWidth: record.benchmarkWidth,
            benchmarkHeight: record.benchmarkHeight,
            benchmarkFrameRate: record.benchmarkFrameRate,
            encodeMs: record.hostEncodeMs,
            benchmarkVersion: record.version
        )

        if let message = try? ControlMessage(type: .qualityTestResult, content: result) {
            connection.send(content: message.serialize(), completion: .idempotent)
        }
    }

    private static func sendQualityTestPackets(
        to connection: NWConnection,
        testID: UUID,
        plan: MirageQualityTestPlan,
        payloadBytes: Int
    ) async {
        let payloadLength = UInt16(clamping: payloadBytes)
        let payload = Data(repeating: 0, count: payloadBytes)
        let minIntervalSeconds = 0.001
        let maxBurstPackets = 1024
        var sequence: UInt32 = 0

        for stage in plan.stages {
            let durationSeconds = Double(stage.durationMs) / 1000.0
            let packetSize = Double(payloadBytes + mirageQualityTestHeaderSize)
            let packetsPerSecond = packetSize > 0
                ? (Double(stage.targetBitrateBps) / 8.0) / packetSize
                : 0
            let baseInterval = packetsPerSecond > 0 ? 1.0 / packetsPerSecond : 0
            let tickInterval = baseInterval > 0 ? max(baseInterval, minIntervalSeconds) : 0
            var packetBudget = 0.0
            var stagePacketCount = 0
            var stagePayloadBytes = 0
            let stageStart = CFAbsoluteTimeGetCurrent()
            var lastTickTime = stageStart

            let targetMbps = Double(stage.targetBitrateBps) / 1_000_000.0
            let packetSizeText = Int(packetSize)
            let ppsText = packetsPerSecond.formatted(.number.precision(.fractionLength(1)))
            let intervalMs = (tickInterval * 1000.0).formatted(.number.precision(.fractionLength(2)))
            MirageLogger.host(
                "Quality test stage \(stage.id): target \(targetMbps.formatted(.number.precision(.fractionLength(1)))) Mbps, duration \(stage.durationMs)ms, payload \(payloadBytes)B, packet \(packetSizeText)B, pps \(ppsText), tick \(intervalMs)ms"
            )

            while CFAbsoluteTimeGetCurrent() - stageStart < durationSeconds {
                if Task.isCancelled { return }
                guard packetsPerSecond > 0 else {
                    await Task.yield()
                    continue
                }

                let now = CFAbsoluteTimeGetCurrent()
                let delta = max(0, now - lastTickTime)
                lastTickTime = now
                packetBudget += packetsPerSecond * delta
                var desiredCount = Int(packetBudget)
                if desiredCount > 0 {
                    let sendCount = min(desiredCount, maxBurstPackets)
                    packetBudget -= Double(sendCount)
                    for _ in 0 ..< sendCount {
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
                        connection.send(content: packet, completion: .idempotent)
                        sequence &+= 1
                        stagePacketCount += 1
                        stagePayloadBytes += payloadBytes
                    }
                }

                if tickInterval > 0 {
                    try? await Task.sleep(for: .seconds(tickInterval))
                } else {
                    await Task.yield()
                }
            }

            let actualDuration = max(0.001, CFAbsoluteTimeGetCurrent() - stageStart)
            let sentMbps = (Double(stagePayloadBytes) * 8.0) / actualDuration / 1_000_000.0
            MirageLogger.host(
                "Quality test stage \(stage.id) sent \(stagePacketCount) packets, \(stagePayloadBytes)B payload, duration \(Int(actualDuration * 1000))ms, payload throughput \(sentMbps.formatted(.number.precision(.fractionLength(1)))) Mbps"
            )
        }
    }
}
#endif
