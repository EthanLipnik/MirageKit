//
//  ClientVideoPacketIngressProcessor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import Foundation
import MirageKit

struct ClientVideoIngressMetricsSnapshot: Sendable, Equatable {
    let loomStreamDeliveryPPS: Double
    let loomStreamDeliveryIntervalMaxMs: Double
    let rawPacketIngressPPS: Double
    let incomingBatchRate: Double
    let incomingBatchIntervalP95Ms: Double
    let incomingBatchIntervalP99Ms: Double
    let incomingBatchIntervalMaxMs: Double
    let incomingBatchMaxSize: Int
    let incomingBatchAverageSize: Double
    let queuedBatchCount: Int
    let queuedPacketCount: Int
    let queueAgeMaxMs: Double
    let stalePacketDropCount: UInt64
    let overloadPacketDropCount: UInt64
    let processedPacketCount: UInt64
    let processorWakeDelayMaxMs: Double
}

final class ClientVideoIngressTelemetryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotsByStream: [StreamID: ClientVideoIngressMetricsSnapshot] = [:]

    func update(_ snapshot: ClientVideoIngressMetricsSnapshot, for streamID: StreamID) {
        lock.lock()
        snapshotsByStream[streamID] = snapshot
        lock.unlock()
    }

    func snapshot(for streamID: StreamID) -> ClientVideoIngressMetricsSnapshot? {
        lock.lock()
        let snapshot = snapshotsByStream[streamID]
        lock.unlock()
        return snapshot
    }

    func clear(streamID: StreamID) {
        lock.lock()
        snapshotsByStream.removeValue(forKey: streamID)
        lock.unlock()
    }

    func clearAll() {
        lock.lock()
        snapshotsByStream.removeAll()
        lock.unlock()
    }
}

final class ClientVideoDirectIngressTelemetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var loomStreamDeliverySampler = CountRateSampler()
    private var loomStreamDeliveryIntervalSampler = IngressIntervalSampler()
    private var rawPacketSampler = CountRateSampler()
    private var processedPacketCount: UInt64 = 0

    func recordPacket(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> ClientVideoIngressMetricsSnapshot {
        lock.lock()
        loomStreamDeliverySampler.record(now: now)
        loomStreamDeliveryIntervalSampler.record(now: now)
        rawPacketSampler.record(now: now)
        processedPacketCount &+= 1
        let snapshot = snapshotLocked(now: now)
        lock.unlock()
        return snapshot
    }

    func snapshot(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> ClientVideoIngressMetricsSnapshot {
        lock.lock()
        let snapshot = snapshotLocked(now: now)
        lock.unlock()
        return snapshot
    }

    private func snapshotLocked(now: CFAbsoluteTime) -> ClientVideoIngressMetricsSnapshot {
        let loomDeliveryIntervals = loomStreamDeliveryIntervalSampler.snapshot(now: now)
        return ClientVideoIngressMetricsSnapshot(
            loomStreamDeliveryPPS: loomStreamDeliverySampler.snapshot(now: now),
            loomStreamDeliveryIntervalMaxMs: loomDeliveryIntervals.maxMs,
            rawPacketIngressPPS: rawPacketSampler.snapshot(now: now),
            incomingBatchRate: rawPacketSampler.snapshot(now: now),
            incomingBatchIntervalP95Ms: loomDeliveryIntervals.p95Ms,
            incomingBatchIntervalP99Ms: loomDeliveryIntervals.p99Ms,
            incomingBatchIntervalMaxMs: loomDeliveryIntervals.maxMs,
            incomingBatchMaxSize: 1,
            incomingBatchAverageSize: processedPacketCount > 0 ? 1.0 : 0.0,
            queuedBatchCount: 0,
            queuedPacketCount: 0,
            queueAgeMaxMs: 0,
            stalePacketDropCount: 0,
            overloadPacketDropCount: 0,
            processedPacketCount: processedPacketCount,
            processorWakeDelayMaxMs: 0
        )
    }
}

final class ClientVideoPacketIngressProcessor: @unchecked Sendable {
    typealias Snapshot = ClientVideoIngressMetricsSnapshot

    private struct IngressBatch {
        var payloads: [Data]
        let enqueuedAt: CFAbsoluteTime

        var isDropCandidate: Bool {
            !payloads.contains(where: ClientVideoPacketIngressProcessor.isRecoveryPacket)
        }
    }

    private let streamID: StreamID
    private let processPacket: @Sendable (Data, StreamID) -> Void
    private let condition = NSCondition()
    private var workerThread: Thread?
    private var queuedBatches: [IngressBatch] = []
    private var queuedBatchStartIndex: Int = 0
    private var queuedPacketCount: Int = 0
    private var isFinishing = false
    private var loomStreamDeliverySampler = CountRateSampler()
    private var loomStreamDeliveryIntervalSampler = IngressIntervalSampler()
    private var rawPacketSampler = CountRateSampler()
    private var incomingBatchSampler = CountRateSampler()
    private var incomingBatchIntervalSampler = IngressIntervalSampler()
    private var incomingBatchMaxSize: Int = 0
    private var incomingBatchTotalSize: UInt64 = 0
    private var incomingBatchCount: UInt64 = 0
    private var queueAgeMaxMs: Double = 0
    private var stalePacketDropCount: UInt64 = 0
    private var overloadPacketDropCount: UInt64 = 0
    private var processedPacketCount: UInt64 = 0
    private var processorWakeDelaySampler = IngressMaximumSampler()

    private let maxQueuedBatches: Int
    private let maxQueuedPackets: Int
    private let staleNonRecoveryPacketAge: CFTimeInterval

    init(
        streamID: StreamID,
        maxQueuedBatches: Int = 4096,
        maxQueuedPackets: Int = 4096,
        staleNonRecoveryPacketAge: CFTimeInterval = 0.025,
        processPacket: @escaping @Sendable (Data, StreamID) -> Void
    ) {
        self.streamID = streamID
        self.processPacket = processPacket
        self.maxQueuedBatches = max(1, maxQueuedBatches)
        self.maxQueuedPackets = max(1, maxQueuedPackets)
        self.staleNonRecoveryPacketAge = max(0.001, staleNonRecoveryPacketAge)
        let thread = Thread { [weak self] in
            self?.runWorker()
        }
        thread.name = "com.ethanlipnik.mirage.client.video-ingress.\(streamID)"
        thread.qualityOfService = .userInitiated
        workerThread = thread
        thread.start()
    }

    deinit {
        finish()
    }

    func enqueue(_ payloads: [Data]) {
        guard !payloads.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        condition.lock()
        guard !isFinishing else {
            condition.unlock()
            return
        }

        loomStreamDeliverySampler.record(count: payloads.count, now: now)
        loomStreamDeliveryIntervalSampler.record(now: now)
        rawPacketSampler.record(count: payloads.count, now: now)
        incomingBatchSampler.record(now: now)
        incomingBatchIntervalSampler.record(now: now)
        incomingBatchMaxSize = max(incomingBatchMaxSize, payloads.count)
        incomingBatchTotalSize &+= UInt64(payloads.count)
        incomingBatchCount &+= 1

        queuedBatches.append(IngressBatch(
            payloads: payloads,
            enqueuedAt: now
        ))
        queuedPacketCount += payloads.count
        trimStaleNonRecoveryPacketsLocked(now: now)
        trimQueueIfNeededLocked(now: now)
        updateQueueAgeLocked(now: now)
        condition.signal()
        condition.unlock()
    }

    func finish() {
        condition.lock()
        guard !isFinishing else {
            condition.unlock()
            return
        }
        isFinishing = true
        condition.signal()
        condition.unlock()
    }

    func snapshot(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Snapshot {
        condition.lock()
        trimStaleNonRecoveryPacketsLocked(now: now)
        let loomStreamDeliveryPPS = loomStreamDeliverySampler.snapshot(now: now)
        let loomDeliveryIntervals = loomStreamDeliveryIntervalSampler.snapshot(now: now)
        let rawPacketIngressPPS = rawPacketSampler.snapshot(now: now)
        let incomingBatchRate = incomingBatchSampler.snapshot(now: now)
        let batchIntervals = incomingBatchIntervalSampler.snapshot(now: now)
        let activeQueuedBatches = max(0, queuedBatches.count - queuedBatchStartIndex)
        let queuedPacketCount = queuedPacketCount
        updateQueueAgeLocked(now: now)
        let queueAgeMaxMs = queueAgeMaxMs
        let incomingBatchMaxSize = incomingBatchMaxSize
        let incomingBatchAverageSize = incomingBatchCount > 0
            ? Double(incomingBatchTotalSize) / Double(incomingBatchCount)
            : 0
        let stalePacketDropCount = stalePacketDropCount
        let overloadPacketDropCount = overloadPacketDropCount
        let processedPacketCount = processedPacketCount
        let processorWakeDelayMaxMs = processorWakeDelaySampler.snapshot(now: now)
        condition.unlock()
        return Snapshot(
            loomStreamDeliveryPPS: loomStreamDeliveryPPS,
            loomStreamDeliveryIntervalMaxMs: loomDeliveryIntervals.maxMs,
            rawPacketIngressPPS: rawPacketIngressPPS,
            incomingBatchRate: incomingBatchRate,
            incomingBatchIntervalP95Ms: batchIntervals.p95Ms,
            incomingBatchIntervalP99Ms: batchIntervals.p99Ms,
            incomingBatchIntervalMaxMs: batchIntervals.maxMs,
            incomingBatchMaxSize: incomingBatchMaxSize,
            incomingBatchAverageSize: incomingBatchAverageSize,
            queuedBatchCount: activeQueuedBatches,
            queuedPacketCount: queuedPacketCount,
            queueAgeMaxMs: queueAgeMaxMs,
            stalePacketDropCount: stalePacketDropCount,
            overloadPacketDropCount: overloadPacketDropCount,
            processedPacketCount: processedPacketCount,
            processorWakeDelayMaxMs: processorWakeDelayMaxMs
        )
    }

    private func runWorker() {
        while let batch = waitForNextBatch() {
            process(batch)
        }
    }

    private func waitForNextBatch() -> IngressBatch? {
        condition.lock()
        while true {
            while queuedBatchStartIndex >= queuedBatches.count, !isFinishing {
                condition.wait()
            }
            trimStaleNonRecoveryPacketsLocked(now: CFAbsoluteTimeGetCurrent())
            guard queuedBatchStartIndex < queuedBatches.count else {
                if isFinishing {
                    condition.unlock()
                    return nil
                }
                continue
            }

            let batch = queuedBatches[queuedBatchStartIndex]
            queuedBatchStartIndex += 1
            queuedPacketCount = max(0, queuedPacketCount - batch.payloads.count)
            if queuedBatchStartIndex > 128 {
                queuedBatches.removeFirst(queuedBatchStartIndex)
                queuedBatchStartIndex = 0
            }

            let now = CFAbsoluteTimeGetCurrent()
            processorWakeDelaySampler.record(
                max(0, now - batch.enqueuedAt) * 1000,
                now: now
            )
            condition.unlock()
            return batch
        }
    }

    private func process(_ batch: IngressBatch) {
        for payload in batch.payloads {
            processPacket(payload, streamID)
        }
        condition.lock()
        processedPacketCount &+= UInt64(batch.payloads.count)
        condition.unlock()
    }

    private func trimQueueIfNeededLocked(now: CFAbsoluteTime) {
        while queuedBatches.count - queuedBatchStartIndex > maxQueuedBatches ||
            queuedPacketCount > maxQueuedPackets {
            if dropOldestDroppableBatchLocked() { continue }
            _ = dropBatchLocked(at: queuedBatchStartIndex)
        }
        updateQueueAgeLocked(now: now)
    }

    private func trimStaleNonRecoveryPacketsLocked(now: CFAbsoluteTime) {
        guard queuedBatchStartIndex < queuedBatches.count else {
            updateQueueAgeLocked(now: now)
            return
        }

        let cutoff = now - staleNonRecoveryPacketAge
        var index = queuedBatchStartIndex
        var droppedCount = 0
        while index < queuedBatches.count {
            guard queuedBatches[index].enqueuedAt <= cutoff else {
                index += 1
                continue
            }

            let originalCount = queuedBatches[index].payloads.count
            queuedBatches[index].payloads.removeAll { !Self.isRecoveryPacket($0) }
            let removedCount = originalCount - queuedBatches[index].payloads.count
            if queuedBatches[index].payloads.isEmpty {
                queuedBatches.remove(at: index)
            } else {
                index += 1
            }
            droppedCount += removedCount
        }

        if droppedCount > 0 {
            queuedPacketCount = max(0, queuedPacketCount - droppedCount)
            stalePacketDropCount &+= UInt64(droppedCount)
        }
        updateQueueAgeLocked(now: now)
    }

    private func dropOldestDroppableBatchLocked() -> Bool {
        guard queuedBatchStartIndex < queuedBatches.count else { return false }
        if queuedBatches[queuedBatchStartIndex].isDropCandidate {
            _ = dropBatchLocked(at: queuedBatchStartIndex)
            return true
        }
        let searchRange = (queuedBatchStartIndex + 1) ..< queuedBatches.count
        if let index = searchRange.first(where: { queuedBatches[$0].isDropCandidate }) {
            _ = dropBatchLocked(at: index)
            return true
        }
        return false
    }

    @discardableResult
    private func dropBatchLocked(at index: Int) -> Int {
        guard index >= queuedBatchStartIndex, index < queuedBatches.count else { return 0 }
        let dropped = queuedBatches[index].payloads.count
        queuedBatches.remove(at: index)
        queuedPacketCount = max(0, queuedPacketCount - dropped)
        overloadPacketDropCount &+= UInt64(dropped)
        return dropped
    }

    private func updateQueueAgeLocked(now: CFAbsoluteTime) {
        guard queuedBatchStartIndex < queuedBatches.count else {
            queueAgeMaxMs = 0
            return
        }
        queueAgeMaxMs = max(0, (now - queuedBatches[queuedBatchStartIndex].enqueuedAt) * 1000)
    }

    private static func isRecoveryPacket(_ data: Data) -> Bool {
        guard data.count >= mirageHeaderSize, let header = FrameHeader.deserialize(from: data) else {
            return false
        }
        return header.flags.contains(.keyframe) ||
            header.flags.contains(.parameterSet) ||
            header.flags.contains(.discontinuity) ||
            header.flags.contains(.priority)
    }
}

private struct CountRateSampler {
    private struct Sample {
        let timestamp: CFAbsoluteTime
        let count: Int
    }

    private var samples: [Sample] = []
    private var startIndex = 0
    private let windowSeconds: CFAbsoluteTime = 1.0

    mutating func record(count: Int = 1, now: CFAbsoluteTime) {
        samples.append(Sample(timestamp: now, count: max(0, count)))
        trim(now: now)
    }

    mutating func snapshot(now: CFAbsoluteTime) -> Double {
        trim(now: now)
        guard startIndex < samples.count else { return 0 }
        return Double(samples[startIndex ..< samples.count].reduce(0) { $0 + $1.count })
    }

    private mutating func trim(now: CFAbsoluteTime) {
        let cutoff = now - windowSeconds
        while startIndex < samples.count, samples[startIndex].timestamp < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }
}

private struct IngressIntervalSampler {
    private struct Sample {
        let timestamp: CFAbsoluteTime
        let intervalMs: Double
    }

    struct Snapshot: Sendable, Equatable {
        let p95Ms: Double
        let p99Ms: Double
        let maxMs: Double
    }

    private var lastSampleTime: CFAbsoluteTime = 0
    private var samples: [Sample] = []
    private var startIndex = 0
    private let windowSeconds: CFAbsoluteTime = 2.0

    mutating func record(now: CFAbsoluteTime) {
        trim(now: now)
        guard lastSampleTime > 0 else {
            lastSampleTime = now
            return
        }
        let intervalMs = max(0, (now - lastSampleTime) * 1000)
        lastSampleTime = now
        samples.append(Sample(timestamp: now, intervalMs: intervalMs))
    }

    mutating func snapshot(now: CFAbsoluteTime) -> Snapshot {
        trim(now: now)
        guard startIndex < samples.count else {
            return Snapshot(p95Ms: 0, p99Ms: 0, maxMs: 0)
        }
        let active = samples[startIndex ..< samples.count].map(\.intervalMs)
        guard !active.isEmpty else {
            return Snapshot(p95Ms: 0, p99Ms: 0, maxMs: 0)
        }
        let sorted = active.sorted()
        return Snapshot(
            p95Ms: percentile(sorted: sorted, percentile: 0.95),
            p99Ms: percentile(sorted: sorted, percentile: 0.99),
            maxMs: active.max() ?? 0
        )
    }

    private mutating func trim(now: CFAbsoluteTime) {
        let cutoff = now - windowSeconds
        while startIndex < samples.count, samples[startIndex].timestamp < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }

    private func percentile(sorted: [Double], percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = max(0, min(1, percentile))
        let index = Int(ceil(clamped * Double(sorted.count))) - 1
        return sorted[max(0, min(sorted.count - 1, index))]
    }
}

private struct IngressMaximumSampler {
    private struct Sample {
        let timestamp: CFAbsoluteTime
        let value: Double
    }

    private var samples: [Sample] = []
    private var startIndex = 0
    private let windowSeconds: CFAbsoluteTime = 2.0

    mutating func record(_ value: Double, now: CFAbsoluteTime) {
        samples.append(Sample(timestamp: now, value: max(0, value)))
        trim(now: now)
    }

    mutating func snapshot(now: CFAbsoluteTime) -> Double {
        trim(now: now)
        guard startIndex < samples.count else { return 0 }
        return samples[startIndex ..< samples.count].map(\.value).max() ?? 0
    }

    private mutating func trim(now: CFAbsoluteTime) {
        let cutoff = now - windowSeconds
        while startIndex < samples.count, samples[startIndex].timestamp < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }
}
