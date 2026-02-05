//
//  MirageClientService+QualityProbeTransport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/4/26.
//
//  Transport probe helpers for automatic quality testing.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func startQualityProbeTransport(streamID: StreamID) async -> FrameReassembler {
        let payloadSize = miragePayloadSize(maxPacketSize: networkConfig.maxPacketSize)
        let controller = StreamController(streamID: streamID, maxPayloadSize: payloadSize)
        let reassembler = await controller.getReassembler()
        reassembler.setFrameHandler { _, _, _, _, _, releaseBuffer in
            releaseBuffer()
        }
        reassembler.setFrameLossHandler { _ in }
        controllersByStream[streamID] = controller
        qualityProbeTransportController = controller
        qualityProbeTransportStreamID = streamID
        qualityProbeTransportLock.withLock {
            qualityProbeTransportStreamIDStorage = streamID
        }
        addActiveStreamID(streamID)
        await updateReassemblerSnapshot()
        return reassembler
    }

    func stopQualityProbeTransport(streamID: StreamID) async {
        removeActiveStreamID(streamID)
        if let controller = controllersByStream.removeValue(forKey: streamID) {
            await controller.stop()
        }
        qualityProbeTransportController = nil
        qualityProbeTransportStreamID = nil
        qualityProbeTransportLock.withLock {
            qualityProbeTransportStreamIDStorage = nil
        }
        await updateReassemblerSnapshot()
    }

    func transportThroughput() -> Int? {
        let snapshot = qualityProbeTransportAccumulator.snapshot()
        guard snapshot.bytes > 0, snapshot.lastTime > snapshot.firstTime else { return nil }
        let elapsed = max(0.001, snapshot.lastTime - snapshot.firstTime)
        return Int((Double(snapshot.bytes) * 8.0) / elapsed)
    }

    func transportLoss(reassembler: FrameReassembler?) -> Double? {
        guard let reassembler else { return nil }
        let metrics = reassembler.snapshotMetrics()
        let total = metrics.framesDelivered + metrics.droppedFrames
        guard total > 0 else { return nil }
        return (Double(metrics.droppedFrames) / Double(total)) * 100.0
    }

    nonisolated func recordQualityProbeTransportBytes(_ count: Int) {
        qualityProbeTransportAccumulator.record(bytes: count)
    }
}

final class QualityProbeTransportAccumulator: @unchecked Sendable {
    struct Snapshot {
        let bytes: Int
        let firstTime: CFAbsoluteTime
        let lastTime: CFAbsoluteTime
    }

    private let lock = NSLock()
    private var bytes: Int = 0
    private var firstTime: CFAbsoluteTime = 0
    private var lastTime: CFAbsoluteTime = 0

    func reset() {
        lock.lock()
        bytes = 0
        firstTime = 0
        lastTime = 0
        lock.unlock()
    }

    func record(bytes count: Int) {
        guard count > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        bytes += count
        if firstTime == 0 { firstTime = now }
        lastTime = now
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(bytes: bytes, firstTime: firstTime, lastTime: lastTime)
        lock.unlock()
        return snapshot
    }
}
