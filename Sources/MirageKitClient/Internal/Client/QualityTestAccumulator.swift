//
//  QualityTestAccumulator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Thread-safe accumulation for quality test UDP packets.
//

import Foundation
import MirageKit

final class QualityTestAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var bytesByStage: [Int: Int] = [:]
    private var packetsByStage: [Int: Int] = [:]
    private var minSequenceByStage: [Int: UInt32] = [:]
    private var maxSequenceByStage: [Int: UInt32] = [:]
    private var minTimestampNsByStage: [Int: UInt64] = [:]
    private var maxTimestampNsByStage: [Int: UInt64] = [:]

    let testID: UUID
    let plan: MirageQualityTestPlan
    let payloadBytes: Int

    init(testID: UUID, plan: MirageQualityTestPlan, payloadBytes: Int) {
        self.testID = testID
        self.plan = plan
        self.payloadBytes = payloadBytes
    }

    func record(header: QualityTestPacketHeader, payloadBytes: Int) {
        let stageID = Int(header.stageID)
        lock.lock()
        bytesByStage[stageID, default: 0] += payloadBytes
        packetsByStage[stageID, default: 0] += 1
        if let minSequence = minSequenceByStage[stageID] {
            minSequenceByStage[stageID] = min(minSequence, header.sequenceNumber)
        } else {
            minSequenceByStage[stageID] = header.sequenceNumber
        }
        if let maxSequence = maxSequenceByStage[stageID] {
            maxSequenceByStage[stageID] = max(maxSequence, header.sequenceNumber)
        } else {
            maxSequenceByStage[stageID] = header.sequenceNumber
        }
        if let minTimestamp = minTimestampNsByStage[stageID] {
            minTimestampNsByStage[stageID] = min(minTimestamp, header.timestampNs)
        } else {
            minTimestampNsByStage[stageID] = header.timestampNs
        }
        if let maxTimestamp = maxTimestampNsByStage[stageID] {
            maxTimestampNsByStage[stageID] = max(maxTimestamp, header.timestampNs)
        } else {
            maxTimestampNsByStage[stageID] = header.timestampNs
        }
        lock.unlock()
    }

    func makeStageResults() -> [MirageQualityTestSummary.StageResult] {
        lock.lock()
        let bytesSnapshot = bytesByStage
        let packetsSnapshot = packetsByStage
        let minSequenceSnapshot = minSequenceByStage
        let maxSequenceSnapshot = maxSequenceByStage
        let minTimestampSnapshot = minTimestampNsByStage
        let maxTimestampSnapshot = maxTimestampNsByStage
        lock.unlock()

        return plan.stages.map { stage in
            let receivedBytes = bytesSnapshot[stage.id, default: 0]
            let packetCount = packetsSnapshot[stage.id, default: 0]
            let minSequence = minSequenceSnapshot[stage.id]
            let maxSequence = maxSequenceSnapshot[stage.id]
            let minTimestamp = minTimestampSnapshot[stage.id]
            let maxTimestamp = maxTimestampSnapshot[stage.id]
            let packetBytes = payloadBytes + mirageQualityTestHeaderSize
            let payloadRatio = packetBytes > 0
                ? Double(payloadBytes) / Double(packetBytes)
                : 1.0
            let expectedBytes = max(
                0,
                Int(Double(stage.targetBitrateBps) * Double(stage.durationMs) / 1000.0 / 8.0 * payloadRatio)
            )
            let measuredDurationMs: Double = {
                guard packetCount >= 10,
                      let minTimestamp,
                      let maxTimestamp,
                      maxTimestamp > minTimestamp else {
                    return Double(stage.durationMs)
                }
                let durationMs = Double(maxTimestamp - minTimestamp) / 1_000_000.0
                return max(1.0, durationMs)
            }()
            let throughputBps = measuredDurationMs > 0
                ? Int(Double(receivedBytes * 8) / (measuredDurationMs / 1000.0))
                : 0
            let lossPercent: Double = {
                if let minSequence, let maxSequence, maxSequence >= minSequence {
                    let expectedPackets = Int(maxSequence - minSequence + 1)
                    guard expectedPackets > 0 else { return 0 }
                    return max(0, (1 - Double(packetCount) / Double(expectedPackets)) * 100)
                }
                guard expectedBytes > 0 else { return 0 }
                return max(0, (1 - Double(receivedBytes) / Double(expectedBytes)) * 100)
            }()

            return MirageQualityTestSummary.StageResult(
                stageID: stage.id,
                targetBitrateBps: stage.targetBitrateBps,
                durationMs: stage.durationMs,
                throughputBps: throughputBps,
                lossPercent: lossPercent
            )
        }
    }

    func stageMetrics(for stage: MirageQualityTestPlan.Stage) -> (expectedBytes: Int, receivedBytes: Int, packetCount: Int) {
        lock.lock()
        let receivedBytes = bytesByStage[stage.id, default: 0]
        let packetCount = packetsByStage[stage.id, default: 0]
        lock.unlock()

        let packetBytes = payloadBytes + mirageQualityTestHeaderSize
        let payloadRatio = packetBytes > 0
            ? Double(payloadBytes) / Double(packetBytes)
            : 1.0
        let expectedBytes = max(
            0,
            Int(Double(stage.targetBitrateBps) * Double(stage.durationMs) / 1000.0 / 8.0 * payloadRatio)
        )
        return (expectedBytes, receivedBytes, packetCount)
    }
}
