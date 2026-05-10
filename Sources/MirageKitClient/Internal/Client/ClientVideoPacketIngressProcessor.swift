//
//  ClientVideoPacketIngressProcessor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import Foundation
import MirageKit

final class ClientVideoPacketIngressProcessor: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        let loomStreamDeliveryFPS: Double
        let loomStreamDeliveryIntervalMaxMs: Double
        let rawPacketIngressFPS: Double
        let incomingBatchFPS: Double
        let incomingBatchIntervalP95Ms: Double
        let incomingBatchIntervalP99Ms: Double
        let incomingBatchIntervalMaxMs: Double
        let incomingBatchMaxSize: Int
        let incomingBatchAverageSize: Double
        let queuedBatchCount: Int
        let queuedPacketCount: Int
        let queueAgeMaxMs: Double
        let stalePacketDropCount: UInt64
        let processedPacketCount: UInt64
        let processorWakeDelayMaxMs: Double
    }

    private struct IngressBatch {
        let payloads: [Data]
        let enqueuedAt: CFAbsoluteTime
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
    private var processedPacketCount: UInt64 = 0
    private var processorWakeDelayMaxMs: Double = 0

    private let maxQueuedBatches: Int
    private let maxQueuedPackets: Int

    init(
        streamID: StreamID,
        maxQueuedBatches: Int = 256,
        maxQueuedPackets: Int = 4096,
        processPacket: @escaping @Sendable (Data, StreamID) -> Void
    ) {
        self.streamID = streamID
        self.processPacket = processPacket
        self.maxQueuedBatches = max(1, maxQueuedBatches)
        self.maxQueuedPackets = max(1, maxQueuedPackets)
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

        queuedBatches.append(IngressBatch(payloads: payloads, enqueuedAt: now))
        queuedPacketCount += payloads.count
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
        let loomStreamDeliveryFPS = loomStreamDeliverySampler.snapshot(now: now)
        let loomDeliveryIntervals = loomStreamDeliveryIntervalSampler.snapshot(now: now)
        let rawPacketIngressFPS = rawPacketSampler.snapshot(now: now)
        let incomingBatchFPS = incomingBatchSampler.snapshot(now: now)
        let batchIntervals = incomingBatchIntervalSampler.snapshot(now: now)
        let activeQueuedBatches = queuedBatches.count - queuedBatchStartIndex
        let queuedPacketCount = queuedPacketCount
        updateQueueAgeLocked(now: now)
        let queueAgeMaxMs = queueAgeMaxMs
        let incomingBatchMaxSize = incomingBatchMaxSize
        let incomingBatchAverageSize = incomingBatchCount > 0
            ? Double(incomingBatchTotalSize) / Double(incomingBatchCount)
            : 0
        let stalePacketDropCount = stalePacketDropCount
        let processedPacketCount = processedPacketCount
        let processorWakeDelayMaxMs = processorWakeDelayMaxMs
        condition.unlock()
        return Snapshot(
            loomStreamDeliveryFPS: loomStreamDeliveryFPS,
            loomStreamDeliveryIntervalMaxMs: loomDeliveryIntervals.maxMs,
            rawPacketIngressFPS: rawPacketIngressFPS,
            incomingBatchFPS: incomingBatchFPS,
            incomingBatchIntervalP95Ms: batchIntervals.p95Ms,
            incomingBatchIntervalP99Ms: batchIntervals.p99Ms,
            incomingBatchIntervalMaxMs: batchIntervals.maxMs,
            incomingBatchMaxSize: incomingBatchMaxSize,
            incomingBatchAverageSize: incomingBatchAverageSize,
            queuedBatchCount: activeQueuedBatches,
            queuedPacketCount: queuedPacketCount,
            queueAgeMaxMs: queueAgeMaxMs,
            stalePacketDropCount: stalePacketDropCount,
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
        while queuedBatchStartIndex >= queuedBatches.count, !isFinishing {
            condition.wait()
        }
        guard queuedBatchStartIndex < queuedBatches.count else {
            condition.unlock()
            return nil
        }

        let batch: IngressBatch?
        batch = queuedBatches[queuedBatchStartIndex]
        queuedBatchStartIndex += 1
        queuedPacketCount = max(0, queuedPacketCount - (batch?.payloads.count ?? 0))
        if queuedBatchStartIndex > 128 {
            queuedBatches.removeFirst(queuedBatchStartIndex)
            queuedBatchStartIndex = 0
        }
        if let batch {
            processorWakeDelayMaxMs = max(
                processorWakeDelayMaxMs,
                max(0, CFAbsoluteTimeGetCurrent() - batch.enqueuedAt) * 1000
            )
        }
        condition.unlock()
        return batch
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
            let dropped = queuedBatches[queuedBatchStartIndex].payloads.count
            queuedBatchStartIndex += 1
            queuedPacketCount = max(0, queuedPacketCount - dropped)
            stalePacketDropCount &+= UInt64(dropped)
        }
        updateQueueAgeLocked(now: now)
    }

    private func updateQueueAgeLocked(now: CFAbsoluteTime) {
        guard queuedBatchStartIndex < queuedBatches.count else {
            queueAgeMaxMs = 0
            return
        }
        queueAgeMaxMs = max(0, (now - queuedBatches[queuedBatchStartIndex].enqueuedAt) * 1000)
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
