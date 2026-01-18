import Foundation

#if os(macOS)

/// Lock-protected inbox for latest captured frames.
/// Keeps only the most recent frame and tracks dropped replacements.
final class StreamFrameInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (SampleBufferWrapper, CapturedFrameInfo)?
    private var droppedCount: UInt64 = 0
    private var isScheduled: Bool = false

    /// Enqueue a frame, returning true if a drain task should be scheduled.
    func enqueue(_ wrapper: SampleBufferWrapper, _ frameInfo: CapturedFrameInfo) -> Bool {
        lock.lock()
        if pending != nil {
            droppedCount += 1
        }
        pending = (wrapper, frameInfo)
        let shouldSchedule = !isScheduled
        if shouldSchedule {
            isScheduled = true
        }
        lock.unlock()
        return shouldSchedule
    }

    /// Take the most recent frame and clear the pending slot.
    func takeLatest() -> (SampleBufferWrapper, CapturedFrameInfo)? {
        lock.lock()
        let item = pending
        pending = nil
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

    func hasPending() -> Bool {
        lock.lock()
        let hasPending = pending != nil
        lock.unlock()
        return hasPending
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
        pending = nil
        lock.unlock()
    }
}

#endif
