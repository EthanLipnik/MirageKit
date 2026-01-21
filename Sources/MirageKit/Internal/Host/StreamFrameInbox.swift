import Foundation

#if os(macOS)

/// Lock-protected inbox for captured frames.
/// Keeps a bounded queue and drops oldest frames when full.
final class StreamFrameInbox: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var buffer: [CapturedFrame?]
    private var headIndex: Int = 0
    private var tailIndex: Int = 0
    private var count: Int = 0
    private var enqueuedCount: UInt64 = 0
    private var droppedCount: UInt64 = 0
    private var isScheduled: Bool = false

    init(capacity: Int = 1) {
        self.capacity = max(1, capacity)
        self.buffer = Array(repeating: nil, count: self.capacity)
    }

    /// Enqueue a frame, returning true if a drain task should be scheduled.
    func enqueue(_ frame: CapturedFrame) -> Bool {
        lock.lock()
        enqueuedCount += 1
        if count == capacity {
            droppedCount += 1
            headIndex = (headIndex + 1) % capacity
            count -= 1
        }
        buffer[tailIndex] = frame
        tailIndex = (tailIndex + 1) % capacity
        count += 1
        let shouldSchedule = !isScheduled
        if shouldSchedule {
            isScheduled = true
        }
        lock.unlock()
        return shouldSchedule
    }

    /// Take the oldest queued frame (FIFO).
    func takeNext() -> CapturedFrame? {
        lock.lock()
        guard count > 0 else {
            lock.unlock()
            return nil
        }
        let item = buffer[headIndex]
        buffer[headIndex] = nil
        headIndex = (headIndex + 1) % capacity
        count -= 1
        lock.unlock()
        return item
    }

    /// Consume dropped-frame count since last read.
    func consumeDroppedCount() -> UInt64 {
        lock.lock()
        let count = droppedCount
        droppedCount = 0
        lock.unlock()
        return count
    }

    /// Consume enqueued-frame count since last read.
    func consumeEnqueuedCount() -> UInt64 {
        lock.lock()
        let count = enqueuedCount
        enqueuedCount = 0
        lock.unlock()
        return count
    }

    func hasPending() -> Bool {
        lock.lock()
        let hasPending = count > 0
        lock.unlock()
        return hasPending
    }

    func pendingCount() -> Int {
        lock.lock()
        let pendingCount = count
        lock.unlock()
        return pendingCount
    }

    /// Request a drain if none is scheduled yet.
    func scheduleIfNeeded() -> Bool {
        lock.lock()
        let shouldSchedule = !isScheduled
        if shouldSchedule {
            isScheduled = true
        }
        lock.unlock()
        return shouldSchedule
    }

    /// Mark the drain as complete.
    func markDrainComplete() {
        lock.lock()
        isScheduled = false
        lock.unlock()
    }

    func clear() {
        lock.lock()
        if count > 0 {
            droppedCount += UInt64(count)
        }
        buffer = Array(repeating: nil, count: capacity)
        headIndex = 0
        tailIndex = 0
        count = 0
        lock.unlock()
    }
}

#endif
