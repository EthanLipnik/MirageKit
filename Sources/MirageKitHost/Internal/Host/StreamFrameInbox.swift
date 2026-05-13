//
//  StreamFrameInbox.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import Foundation
import MirageKit

#if os(macOS)

/// Lock-protected inbox for captured frames.
/// Keeps a bounded queue and drops oldest frames when full.
final class StreamFrameInbox: @unchecked Sendable {
    /// Strategy used when a drain task takes the next frame from the inbox.
    enum DrainPolicy {
        /// Delivers frames in capture order.
        case fifo
        /// Delivers only the newest frame and drops older pending frames.
        case newest
    }

    /// Frame selected for delivery plus the number of pending frames skipped before it.
    struct DrainResult {
        let frame: CapturedFrame?
        let droppedBeforeDelivery: Int
    }

    private let lock = NSLock()
    private let capacity: Int
    private var buffer: [CapturedFrame?]
    private var headIndex: Int = 0
    private var tailIndex: Int = 0
    private var frameCount: Int = 0
    private var enqueuedCount: UInt64 = 0
    private var droppedCount: UInt64 = 0
    /// True while a consumer task has been scheduled but has not reported completion.
    private var isScheduled: Bool = false

    init(capacity: Int = 1) {
        self.capacity = max(1, capacity)
        buffer = Array(repeating: nil, count: self.capacity)
    }

    /// Enqueue a frame, returning true if a drain task should be scheduled.
    func enqueue(_ frame: CapturedFrame) -> Bool {
        let shouldSchedule: Bool
        lock.lock()
        defer { lock.unlock() }
        enqueueLocked(frame)
        shouldSchedule = !isScheduled
        if shouldSchedule { isScheduled = true }
        return shouldSchedule
    }

    /// Enqueues a frame when the caller will schedule draining itself.
    func enqueueWithoutSchedulingSignal(_ frame: CapturedFrame) {
        lock.lock()
        defer { lock.unlock() }
        enqueueLocked(frame)
        if !isScheduled { isScheduled = true }
    }

    private func enqueueLocked(_ frame: CapturedFrame) {
        enqueuedCount += 1
        if frameCount == capacity {
            droppedCount += 1
            headIndex = (headIndex + 1) % capacity
            frameCount -= 1
        }
        buffer[tailIndex] = frame
        tailIndex = (tailIndex + 1) % capacity
        frameCount += 1
    }

    /// Takes the next deliverable frame according to the requested drain policy.
    func takeNext(policy: DrainPolicy = .fifo) -> DrainResult {
        lock.lock()
        defer { lock.unlock() }
        guard frameCount > 0 else {
            return DrainResult(frame: nil, droppedBeforeDelivery: 0)
        }

        switch policy {
        case .fifo:
            let item = buffer[headIndex]
            buffer[headIndex] = nil
            headIndex = (headIndex + 1) % capacity
            frameCount -= 1
            return DrainResult(frame: item, droppedBeforeDelivery: 0)

        case .newest:
            let newestIndex = (tailIndex - 1 + capacity) % capacity
            let item = buffer[newestIndex]
            let droppedBeforeDelivery = max(0, frameCount - 1)
            buffer = Array(repeating: nil, count: capacity)
            headIndex = 0
            tailIndex = 0
            frameCount = 0
            return DrainResult(frame: item, droppedBeforeDelivery: droppedBeforeDelivery)
        }
    }

    func clear() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return discardAllLockedReturningCount()
    }

    /// Drops all pending frames when the caller does not need the cleared count.
    func discardAll() {
        lock.lock()
        defer { lock.unlock() }
        clearStorageLocked()
    }

    private func discardAllLockedReturningCount() -> Int {
        let clearedCount = frameCount
        clearStorageLocked()
        return clearedCount
    }

    private func clearStorageLocked() {
        let clearedCount = frameCount
        if clearedCount > 0 { droppedCount += UInt64(clearedCount) }
        buffer = Array(repeating: nil, count: capacity)
        headIndex = 0
        tailIndex = 0
        frameCount = 0
    }

    /// Consume dropped-frame count since last read.
    func consumeDroppedCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let count = droppedCount
        droppedCount = 0
        return count
    }

    /// Consume enqueued-frame count since last read.
    func consumeEnqueuedCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let count = enqueuedCount
        enqueuedCount = 0
        return count
    }

    var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return frameCount > 0
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCount
    }

    /// Current queue depth and fixed queue capacity for metrics.
    var pendingSnapshot: (pending: Int, capacity: Int) {
        lock.lock()
        defer { lock.unlock() }
        let pending = frameCount
        let queueCapacity = capacity
        return (pending, queueCapacity)
    }

    /// Request a drain if none is scheduled yet.
    func scheduleIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let shouldSchedule = !isScheduled
        if shouldSchedule { isScheduled = true }
        return shouldSchedule
    }

    /// Mark the drain as complete.
    func markDrainComplete() {
        lock.lock()
        defer { lock.unlock() }
        isScheduled = false
    }
}

#endif
