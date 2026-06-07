//
//  ClientVideoPacketIngressProcessor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
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

final class ClientVideoIngressTelemetryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotsByStream: [StreamID: MirageClientVideoIngressMetricsSnapshot] = [:]

    func update(_ snapshot: MirageClientVideoIngressMetricsSnapshot, for streamID: StreamID) {
        lock.lock()
        snapshotsByStream[streamID] = snapshot
        lock.unlock()
    }

    func snapshot(for streamID: StreamID) -> MirageClientVideoIngressMetricsSnapshot? {
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

    func recordPacket(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> MirageClientVideoIngressMetricsSnapshot {
        lock.lock()
        loomStreamDeliverySampler.record(now: now)
        loomStreamDeliveryIntervalSampler.record(now: now)
        rawPacketSampler.record(now: now)
        processedPacketCount &+= 1
        let snapshot = snapshotLocked(now: now)
        lock.unlock()
        return snapshot
    }

    func snapshot(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> MirageClientVideoIngressMetricsSnapshot {
        lock.lock()
        let snapshot = snapshotLocked(now: now)
        lock.unlock()
        return snapshot
    }

    private func snapshotLocked(now: CFAbsoluteTime) -> MirageClientVideoIngressMetricsSnapshot {
        let loomDeliveryIntervals = loomStreamDeliveryIntervalSampler.snapshot(now: now)
        return MirageClientVideoIngressMetricsSnapshot(
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
            protectedOverloadPacketDropCount: 0,
            processedPacketCount: processedPacketCount,
            processorWakeDelayMaxMs: 0
        )
    }
}

final class ClientVideoPacketIngressProcessor: @unchecked Sendable {
    static let defaultStaleNonRecoveryPacketAge: CFTimeInterval = 0.520

    private struct IngressBatch {
        var payloads: [Data]
        let enqueuedAt: CFAbsoluteTime

        var containsNonRecoveryPacket: Bool {
            payloads.contains { !ClientVideoPacketIngressProcessor.isRecoveryPacket($0) }
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
    private var protectedOverloadPacketDropCount: UInt64 = 0
    private var processedPacketCount: UInt64 = 0
    private var processorWakeDelaySampler = IngressMaximumSampler()

    private let maxQueuedBatches: Int
    private let maxQueuedPackets: Int
    private let staleNonRecoveryPacketAge: CFTimeInterval

    init(
        streamID: StreamID,
        maxQueuedBatches: Int = 4096,
        maxQueuedPackets: Int = 4096,
        staleNonRecoveryPacketAge: CFTimeInterval = defaultStaleNonRecoveryPacketAge,
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

    func snapshot(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> MirageClientVideoIngressMetricsSnapshot {
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
        let protectedOverloadPacketDropCount = protectedOverloadPacketDropCount
        let processedPacketCount = processedPacketCount
        let processorWakeDelayMaxMs = processorWakeDelaySampler.snapshot(now: now)
        condition.unlock()
        return MirageClientVideoIngressMetricsSnapshot(
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
            protectedOverloadPacketDropCount: protectedOverloadPacketDropCount,
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
            if dropOldestNonRecoveryPacketsLocked() { continue }
            guard dropOldestProtectedBatchLocked() else { break }
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

    private func dropOldestNonRecoveryPacketsLocked() -> Bool {
        guard queuedBatchStartIndex < queuedBatches.count else { return false }
        var index = queuedBatchStartIndex
        while index < queuedBatches.count {
            guard queuedBatches[index].containsNonRecoveryPacket else {
                index += 1
                continue
            }

            let originalCount = queuedBatches[index].payloads.count
            queuedBatches[index].payloads.removeAll { !Self.isRecoveryPacket($0) }
            let removedCount = originalCount - queuedBatches[index].payloads.count
            if queuedBatches[index].payloads.isEmpty {
                queuedBatches.remove(at: index)
            }
            queuedPacketCount = max(0, queuedPacketCount - removedCount)
            overloadPacketDropCount &+= UInt64(removedCount)
            return removedCount > 0
        }
        return false
    }

    @discardableResult
    private func dropOldestProtectedBatchLocked() -> Bool {
        guard queuedBatchStartIndex < queuedBatches.count else { return false }
        let dropped = dropBatchLocked(at: queuedBatchStartIndex)
        guard dropped > 0 else { return false }
        protectedOverloadPacketDropCount &+= UInt64(dropped)
        return true
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
        guard data.count >= MirageWire.mirageHeaderSize, let header = MirageWire.FrameHeader.deserialize(from: data) else {
            return false
        }
        return header.flags.contains(.keyframe) ||
            header.flags.contains(.parameterSet) ||
            header.flags.contains(.discontinuity) ||
            header.flags.contains(.priority) ||
            header.flags.contains(.fecParity) ||
            header.fecBlockSize > 1
    }
}
