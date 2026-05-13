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

    let testID: UUID

    init(testID: UUID) {
        self.testID = testID
    }

    func record(header: QualityTestPacketHeader, payloadBytes: Int) {
        let stageID = Int(header.stageID)
        lock.lock()
        defer { lock.unlock() }
        bytesByStage[stageID, default: 0] += payloadBytes
        packetsByStage[stageID, default: 0] += 1
    }

    func receivedMetrics(
        for stageID: Int
    ) -> (receivedPayloadBytes: Int, receivedPacketCount: Int) {
        lock.lock()
        defer { lock.unlock() }

        return (
            receivedPayloadBytes: bytesByStage[stageID, default: 0],
            receivedPacketCount: packetsByStage[stageID, default: 0]
        )
    }
}
