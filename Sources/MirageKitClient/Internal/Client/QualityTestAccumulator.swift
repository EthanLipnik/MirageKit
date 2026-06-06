//
//  QualityTestAccumulator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Thread-safe accumulation for quality test UDP packets.
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

final class QualityTestAccumulator: @unchecked Sendable {
    struct ReceivedMetrics: Equatable {
        let receivedPayloadBytes: Int
        let receivedPacketCount: Int
        let receiveSpanMs: Double?
        let interArrivalP95Ms: Double?
        let interArrivalP99Ms: Double?
    }

    private struct StageReceiveTiming {
        var firstReceiveTime: CFAbsoluteTime?
        var lastReceiveTime: CFAbsoluteTime?
        var previousReceiveTime: CFAbsoluteTime?
        var interArrivalSamplesMs: [Double] = []

        mutating func record(receivedAt: CFAbsoluteTime) {
            if firstReceiveTime == nil {
                firstReceiveTime = receivedAt
            }
            if let previousReceiveTime {
                interArrivalSamplesMs.append(max(0, (receivedAt - previousReceiveTime) * 1_000.0))
            }
            previousReceiveTime = receivedAt
            lastReceiveTime = receivedAt
        }

        var receiveSpanMs: Double? {
            guard let firstReceiveTime, let lastReceiveTime else { return nil }
            return max(0, (lastReceiveTime - firstReceiveTime) * 1_000.0)
        }
    }

    private let lock = NSLock()
    private var bytesByStage: [Int: Int] = [:]
    private var packetsByStage: [Int: Int] = [:]
    private var timingByStage: [Int: StageReceiveTiming] = [:]

    let testID: UUID

    init(testID: UUID) {
        self.testID = testID
    }

    func record(
        header: MirageWire.QualityTestPacketHeader,
        payloadBytes: Int,
        receivedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        let stageID = Int(header.stageID)
        lock.lock()
        defer { lock.unlock() }
        bytesByStage[stageID, default: 0] += payloadBytes
        packetsByStage[stageID, default: 0] += 1
        timingByStage[stageID, default: StageReceiveTiming()].record(receivedAt: receivedAt)
    }

    func receivedMetrics(
        for stageID: Int
    ) -> ReceivedMetrics {
        lock.lock()
        defer { lock.unlock() }

        let timing = timingByStage[stageID]
        return ReceivedMetrics(
            receivedPayloadBytes: bytesByStage[stageID, default: 0],
            receivedPacketCount: packetsByStage[stageID, default: 0],
            receiveSpanMs: timing?.receiveSpanMs,
            interArrivalP95Ms: Self.percentile(timing?.interArrivalSamplesMs ?? [], percentile: 0.95),
            interArrivalP99Ms: Self.percentile(timing?.interArrivalSamplesMs ?? [], percentile: 0.99)
        )
    }

    private static func percentile(_ samples: [Double], percentile: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let clampedPercentile = max(0, min(1, percentile))
        let index = Int((Double(sorted.count - 1) * clampedPercentile).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, index))]
    }
}
