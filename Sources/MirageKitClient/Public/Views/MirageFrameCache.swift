//
//  MirageFrameCache.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import CoreVideo
import Foundation
import Metal
import MirageKit

// MARK: - Global Frame Cache (iOS Gesture Tracking Support)

/// Global frame cache for iOS gesture tracking support.
/// This provides a completely actor-free path for the Metal view to access frames.
/// During iOS gesture tracking (UITrackingRunLoopMode), accessing any @MainActor object
/// can cause synchronous waits that block the entire app. By using a global cache with
/// simple lock-based synchronization, the Metal view's draw loop can access frames
/// without any Swift concurrency overhead.
public final class MirageFrameCache: @unchecked Sendable {
    struct FrameEntry {
        let pixelBuffer: CVPixelBuffer
        let contentRect: CGRect
        let sequence: UInt64
        let decodeTime: CFAbsoluteTime
        let metalTexture: CVMetalTexture?
        let texture: MTLTexture?
    }

    struct EnqueueResult {
        let sequence: UInt64
        let queueDepth: Int
        let oldestAgeMs: Double
        let emergencyDrops: Int
    }

    struct PresentationSnapshot {
        let sequence: UInt64
        let presentedTime: CFAbsoluteTime
    }

    private struct StreamQueue {
        var entries = MirageRingBuffer<FrameEntry>(minimumCapacity: 16)
        var nextSequence: UInt64 = 0
        var lastPresentedSequence: UInt64 = 0
        var lastPresentedTime: CFAbsoluteTime = 0
        var emergencyDropCount: UInt64 = 0
        var lastEmergencyLogTime: CFAbsoluteTime = 0
    }

    /// Shared instance - use this from both decode callbacks and Metal views
    public static let shared = MirageFrameCache()

    private let lock = NSLock()
    private var streamQueues: [StreamID: StreamQueue] = [:]

    /// Normal queue capacity for decode->present handoff.
    private let maxQueueDepth = 12
    /// Sustained backlog threshold used to arm emergency trimming.
    private let emergencyDepthThreshold = 8
    /// Sustained oldest-frame age threshold used to arm emergency trimming.
    private let emergencyOldestAgeMs: Double = 150
    /// Queue depth retained after emergency trimming.
    private let emergencySafeDepth = 4
    /// Presentation catch-up trim threshold. Keep minor jitter backlogs intact to avoid
    /// unnecessary frame loss under normal 60Hz decode jitter.
    private let presentationTrimDepthThreshold = 4
    /// Presentation catch-up latency ceiling (ms). Age-based trimming protects interaction
    /// latency if decode bursts accumulate even below the depth threshold.
    private let presentationTrimOldestAgeMs: Double = 50
    private let emergencyLogInterval: CFAbsoluteTime = 1.0
    private let typingBurstWindow: CFAbsoluteTime = 0.35
    private let typingBurstTrimLogInterval: CFAbsoluteTime = 0.5
    private var typingBurstDeadlines: [StreamID: CFAbsoluteTime] = [:]
    private var lastTypingBurstTrimLogTime: [StreamID: CFAbsoluteTime] = [:]
    private let lockHoldWarnMs: Double = 1.0
    private let lockHoldLogInterval: CFAbsoluteTime = 1.0
    private var lastLockHoldLogTime: [StreamID: CFAbsoluteTime] = [:]

    private init() {}

    /// Store a frame for a stream (called from decode callback).
    public func store(
        _ pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        metalTexture: CVMetalTexture?,
        texture: MTLTexture?,
        for streamID: StreamID
    ) {
        _ = enqueue(
            pixelBuffer,
            contentRect: contentRect,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            metalTexture: metalTexture,
            texture: texture,
            for: streamID
        )
    }

    /// Store a frame with explicit decode time (for render timing diagnostics).
    @discardableResult
    func enqueue(
        _ pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        metalTexture: CVMetalTexture?,
        texture: MTLTexture?,
        for streamID: StreamID
    ) -> EnqueueResult {
        lock.lock()
        var queue = streamQueues[streamID] ?? StreamQueue()
        let nextSequence = queue.nextSequence &+ 1
        queue.nextSequence = nextSequence
        queue.entries.append(
            FrameEntry(
                pixelBuffer: pixelBuffer,
                contentRect: contentRect,
                sequence: nextSequence,
                decodeTime: decodeTime,
                metalTexture: metalTexture,
                texture: texture
            )
        )
        let now = CFAbsoluteTimeGetCurrent()
        let emergencyDrops = applyEmergencyPolicy(
            streamID: streamID,
            queue: &queue,
            now: now
        )
        streamQueues[streamID] = queue
        let depth = queue.entries.count
        let oldestAgeMs = oldestAgeMsLocked(queue: queue, now: now)
        lock.unlock()
        return EnqueueResult(
            sequence: nextSequence,
            queueDepth: depth,
            oldestAgeMs: oldestAgeMs,
            emergencyDrops: emergencyDrops
        )
    }

    /// Backward-compatible wrapper for existing call sites.
    public func store(
        _ pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        metalTexture: CVMetalTexture?,
        texture: MTLTexture?,
        for streamID: StreamID
    ) {
        _ = enqueue(
            pixelBuffer,
            contentRect: contentRect,
            decodeTime: decodeTime,
            metalTexture: metalTexture,
            texture: texture,
            for: streamID
        )
    }

    /// Store a frame for a stream without a prebuilt Metal texture.
    public func store(_ pixelBuffer: CVPixelBuffer, contentRect: CGRect, for streamID: StreamID) {
        _ = enqueue(
            pixelBuffer,
            contentRect: contentRect,
            decodeTime: CFAbsoluteTimeGetCurrent(),
            metalTexture: nil,
            texture: nil,
            for: streamID
        )
    }

    func dequeue(for streamID: StreamID) -> FrameEntry? {
        lock.lock()
        guard var queue = streamQueues[streamID], !queue.entries.isEmpty else {
            lock.unlock()
            return nil
        }
        guard let result = queue.entries.popFirst() else {
            streamQueues[streamID] = queue
            lock.unlock()
            return nil
        }
        streamQueues[streamID] = queue
        lock.unlock()
        return result
    }

    /// Dequeue a frame for real-time presentation.
    /// When decode outruns presentation and the queue is backlogged, this drops stale entries
    /// and returns the newest frame to keep interaction latency bounded.
    func dequeueForPresentation(
        for streamID: StreamID,
        catchUpDepth: Int = 2,
        preferLatest: Bool = false
    ) -> FrameEntry? {
        lock.lock()
        let lockStart = CFAbsoluteTimeGetCurrent()
        guard var queue = streamQueues[streamID], !queue.entries.isEmpty else {
            lock.unlock()
            return nil
        }

        let keepDepth = max(1, catchUpDepth)
        let depth = queue.entries.count
        let now = CFAbsoluteTimeGetCurrent()
        let oldestAgeMs = oldestAgeMsLocked(queue: queue, now: now)
        let typingBurstActive = typingBurstActiveLocked(for: streamID, now: now)
        let effectiveKeepDepth = typingBurstActive ? 1 : keepDepth

        if typingBurstActive {
            let dropCount = max(0, depth - effectiveKeepDepth)
            if dropCount > 0 {
                _ = queue.entries.removeFirst(dropCount)
                queue.emergencyDropCount &+= UInt64(dropCount)
                if MirageLogger.isEnabled(.renderer) {
                    let lastLogTime = lastTypingBurstTrimLogTime[streamID] ?? 0
                    if lastLogTime == 0 || now - lastLogTime >= typingBurstTrimLogInterval {
                        lastTypingBurstTrimLogTime[streamID] = now
                        let ageText = oldestAgeMs.formatted(.number.precision(.fractionLength(1)))
                        MirageLogger
                            .renderer(
                                "Typing burst trim: dropped=\(dropCount) depth=\(depth) keep=1 oldest=\(ageText)ms stream=\(streamID)"
                            )
                    }
                }
            }
        } else {
            let shouldTrimForDepth = depth >= presentationTrimDepthThreshold
            let shouldTrimForAge = depth > effectiveKeepDepth && oldestAgeMs >= presentationTrimOldestAgeMs
            let shouldTrimForPreferLatest = preferLatest && depth > effectiveKeepDepth
            if shouldTrimForAge || shouldTrimForPreferLatest {
                let dropCount = max(0, depth - effectiveKeepDepth)
                if dropCount > 0 {
                    _ = queue.entries.removeFirst(dropCount)
                    queue.emergencyDropCount &+= UInt64(dropCount)
                    if MirageLogger.isEnabled(.renderer),
                       queue.lastEmergencyLogTime == 0 || now - queue.lastEmergencyLogTime >= emergencyLogInterval {
                        queue.lastEmergencyLogTime = now
                        let ageText = oldestAgeMs.formatted(.number.precision(.fractionLength(1)))
                        let reason: String
                        if shouldTrimForPreferLatest {
                            reason = shouldTrimForAge ? "preferLatest+age" : "preferLatest"
                        } else if shouldTrimForDepth {
                            reason = "age+depth"
                        } else {
                            reason = "age"
                        }
                        MirageLogger
                            .renderer(
                                "Render catch-up trim: dropped=\(dropCount) depth=\(depth) keep=\(effectiveKeepDepth) " +
                                    "oldest=\(ageText)ms reason=\(reason) stream=\(streamID)"
                            )
                    }
                }
            }
        }

        guard let result = queue.entries.popFirst() else {
            streamQueues[streamID] = queue
            lock.unlock()
            return nil
        }
        streamQueues[streamID] = queue
        let lockHoldMs = max(0, CFAbsoluteTimeGetCurrent() - lockStart) * 1000
        maybeLogLockHold(
            streamID: streamID,
            holdMs: lockHoldMs,
            now: now
        )
        lock.unlock()
        return result
    }

    func noteTypingBurstActivity(for streamID: StreamID) {
        lock.lock()
        typingBurstDeadlines[streamID] = CFAbsoluteTimeGetCurrent() + typingBurstWindow
        lock.unlock()
    }

    func isTypingBurstActive(for streamID: StreamID, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        lock.lock()
        let active = typingBurstActiveLocked(for: streamID, now: now)
        lock.unlock()
        return active
    }

    private func typingBurstActiveLocked(for streamID: StreamID, now: CFAbsoluteTime) -> Bool {
        guard let deadline = typingBurstDeadlines[streamID] else { return false }
        if now < deadline { return true }
        typingBurstDeadlines.removeValue(forKey: streamID)
        lastTypingBurstTrimLogTime.removeValue(forKey: streamID)
        return false
    }

    func peekLatest(for streamID: StreamID) -> FrameEntry? {
        lock.lock()
        let result = streamQueues[streamID]?.entries.last
        lock.unlock()
        return result
    }

    /// Backward-compatible accessor for call sites that only need the most recent frame metadata.
    func getEntry(for streamID: StreamID) -> FrameEntry? {
        peekLatest(for: streamID)
    }

    func queueDepth(for streamID: StreamID) -> Int {
        lock.lock()
        let depth = streamQueues[streamID]?.entries.count ?? 0
        lock.unlock()
        return depth
    }

    func oldestAgeMs(for streamID: StreamID) -> Double {
        lock.lock()
        let age = oldestAgeMsLocked(queue: streamQueues[streamID], now: CFAbsoluteTimeGetCurrent())
        lock.unlock()
        return age
    }

    func latestSequence(for streamID: StreamID) -> UInt64 {
        lock.lock()
        let sequence = streamQueues[streamID]?.nextSequence ?? 0
        lock.unlock()
        return sequence
    }

    func markPresented(sequence: UInt64, for streamID: StreamID) {
        lock.lock()
        guard var queue = streamQueues[streamID], sequence > queue.lastPresentedSequence else {
            lock.unlock()
            return
        }
        queue.lastPresentedSequence = sequence
        queue.lastPresentedTime = CFAbsoluteTimeGetCurrent()
        streamQueues[streamID] = queue
        lock.unlock()
    }

    func presentationSnapshot(for streamID: StreamID) -> PresentationSnapshot {
        lock.lock()
        let queue = streamQueues[streamID]
        let snapshot = PresentationSnapshot(
            sequence: queue?.lastPresentedSequence ?? 0,
            presentedTime: queue?.lastPresentedTime ?? 0
        )
        lock.unlock()
        return snapshot
    }

    /// Clear frame for a stream (called when stream ends)
    public func clear(for streamID: StreamID) {
        lock.lock()
        streamQueues.removeValue(forKey: streamID)
        typingBurstDeadlines.removeValue(forKey: streamID)
        lastTypingBurstTrimLogTime.removeValue(forKey: streamID)
        lastLockHoldLogTime.removeValue(forKey: streamID)
        lock.unlock()
    }

    private func applyEmergencyPolicy(
        streamID: StreamID,
        queue: inout StreamQueue,
        now: CFAbsoluteTime
    ) -> Int {
        guard !queue.entries.isEmpty else { return 0 }
        let depth = queue.entries.count
        let oldestAgeMs = oldestAgeMsLocked(queue: queue, now: now)
        let shouldTrimForDepth = depth > maxQueueDepth
        let shouldTrimForSustainedBacklog = depth >= emergencyDepthThreshold && oldestAgeMs >= emergencyOldestAgeMs
        guard shouldTrimForDepth || shouldTrimForSustainedBacklog else { return 0 }

        let keepDepth = min(emergencySafeDepth, queue.entries.count)
        let dropCount = max(0, queue.entries.count - keepDepth)
        guard dropCount > 0 else { return 0 }
        _ = queue.entries.removeFirst(dropCount)
        queue.emergencyDropCount &+= UInt64(dropCount)

        if MirageLogger.isEnabled(.renderer),
           queue.lastEmergencyLogTime == 0 || now - queue.lastEmergencyLogTime >= emergencyLogInterval {
            queue.lastEmergencyLogTime = now
            let ageText = oldestAgeMs.formatted(.number.precision(.fractionLength(1)))
            MirageLogger
                .renderer(
                    "Render emergency trim: dropped=\(dropCount) depth=\(depth) oldest=\(ageText)ms stream=\(streamID)"
                )
        }

        return dropCount
    }

    private func oldestAgeMsLocked(queue: StreamQueue?, now: CFAbsoluteTime) -> Double {
        guard let decodeTime = queue?.entries.first?.decodeTime else { return 0 }
        return max(0, now - decodeTime) * 1000
    }

    private func maybeLogLockHold(
        streamID: StreamID,
        holdMs: Double,
        now: CFAbsoluteTime
    ) {
        guard holdMs >= lockHoldWarnMs else { return }
        guard MirageLogger.isEnabled(.renderer) else { return }
        let lastLogTime = lastLockHoldLogTime[streamID] ?? 0
        if lastLogTime > 0, now - lastLogTime < lockHoldLogInterval {
            return
        }
        lastLockHoldLogTime[streamID] = now
        let holdText = holdMs.formatted(.number.precision(.fractionLength(2)))
        let queueDepth = streamQueues[streamID]?.entries.count ?? 0
        MirageLogger.renderer(
            "Frame cache lock hold: stream=\(streamID) hold=\(holdText)ms depth=\(queueDepth)"
        )
    }
}
