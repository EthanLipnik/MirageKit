//
//  MirageRenderStreamStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Per-stream render queue store with frame-available signaling.
//

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MirageKit

final class MirageRenderStreamStore: @unchecked Sendable {
    struct EnqueueResult: Sendable {
        let sequence: UInt64
        let queueDepth: Int
        let oldestAgeMs: Double
        let emergencyDrops: Int
    }

    struct PresentationSnapshot: Sendable {
        let sequence: UInt64
        let presentedTime: CFAbsoluteTime
    }

    static let shared = MirageRenderStreamStore()

    private final class WeakOwner {
        weak var value: AnyObject?

        init(_ value: AnyObject) {
            self.value = value
        }
    }

    private struct FrameListener {
        let owner: WeakOwner
        let callback: @Sendable () -> Void
    }

    private final class StreamState {
        let lock = NSLock()
        let queue: MirageSPSCFrameQueue
        var nextSequence: UInt64 = 0
        var lastPresentedSequence: UInt64 = 0
        var lastPresentedTime: CFAbsoluteTime = 0
        var emergencyDropCount: UInt64 = 0
        var typingBurstDeadline: CFAbsoluteTime = 0
        var listeners: [ObjectIdentifier: FrameListener] = [:]

        init(capacity: Int) {
            queue = MirageSPSCFrameQueue(capacity: capacity)
        }
    }

    private let stateLock = NSLock()
    private var streams: [StreamID: StreamState] = [:]

    private let defaultQueueCapacity = 16
    private let emergencyDepthThreshold = 12
    private let emergencyOldestAgeMs: Double = 150
    private let emergencySafeDepth = 4
    private let presentationTrimOldestAgeMs: Double = 50
    private let typingBurstWindow: CFAbsoluteTime = 0.35

    private init() {}

    @discardableResult
    func enqueue(
        pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        metalTexture: CVMetalTexture?,
        texture: MTLTexture?,
        for streamID: StreamID
    ) -> EnqueueResult {
        let state = streamState(for: streamID)
        let listeners: [@Sendable () -> Void]
        let result: EnqueueResult

        state.lock.lock()
        state.nextSequence &+= 1
        let frame = MirageRenderFrame(
            pixelBuffer: pixelBuffer,
            contentRect: contentRect,
            sequence: state.nextSequence,
            decodeTime: decodeTime,
            metalTexture: metalTexture,
            texture: texture
        )

        let pushResult = state.queue.enqueue(frame)
        var emergencyDrops = pushResult.dropped
        if emergencyDrops > 0 {
            state.emergencyDropCount &+= UInt64(emergencyDrops)
        }

        let now = CFAbsoluteTimeGetCurrent()
        let snapshot = state.queue.snapshot()
        let enqueueOldestAgeMs = oldestAgeMs(snapshot: snapshot, now: now)

        if snapshot.depth >= emergencyDepthThreshold, enqueueOldestAgeMs >= emergencyOldestAgeMs {
            let trimmed = state.queue.trimNewest(keepDepth: emergencySafeDepth)
            if trimmed > 0 {
                emergencyDrops += trimmed
                state.emergencyDropCount &+= UInt64(trimmed)
            }
        }

        let postTrimSnapshot = state.queue.snapshot()
        result = EnqueueResult(
            sequence: frame.sequence,
            queueDepth: postTrimSnapshot.depth,
            oldestAgeMs: oldestAgeMs(snapshot: postTrimSnapshot, now: now),
            emergencyDrops: emergencyDrops
        )

        listeners = activeListenersLocked(state: state)
        state.lock.unlock()

        for callback in listeners {
            callback()
        }

        return result
    }

    func dequeue(for streamID: StreamID) -> MirageRenderFrame? {
        let state = streamStateIfPresent(for: streamID)
        return state?.queue.dequeue()
    }

    func dequeueForPresentation(
        for streamID: StreamID,
        catchUpDepth: Int,
        preferLatest: Bool
    ) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }

        state.lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let typingBurstActive = typingBurstActiveLocked(state: state, now: now)
        let keepDepth = max(1, catchUpDepth)
        let effectiveKeepDepth = typingBurstActive ? 1 : keepDepth

        let snapshot = state.queue.snapshot()
        if snapshot.depth == 0 {
            state.lock.unlock()
            return nil
        }

        let oldestAgeMs = oldestAgeMs(snapshot: snapshot, now: now)
        let shouldTrimForLatency = snapshot.depth > effectiveKeepDepth && oldestAgeMs >= presentationTrimOldestAgeMs
        let shouldTrimForLatest = snapshot.depth > effectiveKeepDepth && (typingBurstActive || preferLatest)

        if shouldTrimForLatency || shouldTrimForLatest {
            let trimmed = state.queue.trimNewest(keepDepth: effectiveKeepDepth)
            if trimmed > 0 {
                state.emergencyDropCount &+= UInt64(trimmed)
            }
        }

        let frame = state.queue.dequeue()
        state.lock.unlock()
        return frame
    }

    func peekLatest(for streamID: StreamID) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        return state.queue.peekLatest()
    }

    func queueDepth(for streamID: StreamID) -> Int {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        return state.queue.snapshot().depth
    }

    func oldestAgeMs(for streamID: StreamID, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Double {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        let snapshot = state.queue.snapshot()
        return oldestAgeMs(snapshot: snapshot, now: now)
    }

    func latestSequence(for streamID: StreamID) -> UInt64 {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        return state.queue.snapshot().latestSequence
    }

    func markPresented(sequence: UInt64, for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        guard sequence > state.lastPresentedSequence else {
            state.lock.unlock()
            return
        }
        state.lastPresentedSequence = sequence
        state.lastPresentedTime = CFAbsoluteTimeGetCurrent()
        state.lock.unlock()
    }

    func presentationSnapshot(for streamID: StreamID) -> PresentationSnapshot {
        guard let state = streamStateIfPresent(for: streamID) else {
            return PresentationSnapshot(sequence: 0, presentedTime: 0)
        }

        state.lock.lock()
        let snapshot = PresentationSnapshot(sequence: state.lastPresentedSequence, presentedTime: state.lastPresentedTime)
        state.lock.unlock()
        return snapshot
    }

    func noteTypingBurstActivity(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.typingBurstDeadline = CFAbsoluteTimeGetCurrent() + typingBurstWindow
        state.lock.unlock()
    }

    func isTypingBurstActive(for streamID: StreamID, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        guard let state = streamStateIfPresent(for: streamID) else { return false }
        state.lock.lock()
        let active = typingBurstActiveLocked(state: state, now: now)
        state.lock.unlock()
        return active
    }

    func registerFrameListener(
        for streamID: StreamID,
        owner: AnyObject,
        callback: @escaping @Sendable () -> Void
    ) {
        let state = streamState(for: streamID)
        state.lock.lock()
        let key = ObjectIdentifier(owner)
        state.listeners[key] = FrameListener(owner: WeakOwner(owner), callback: callback)
        state.lock.unlock()
    }

    func unregisterFrameListener(for streamID: StreamID, owner: AnyObject) {
        guard let state = streamStateIfPresent(for: streamID) else { return }
        state.lock.lock()
        state.listeners.removeValue(forKey: ObjectIdentifier(owner))
        state.lock.unlock()
    }

    func clear(for streamID: StreamID) {
        stateLock.lock()
        let state = streams.removeValue(forKey: streamID)
        stateLock.unlock()

        guard let state else { return }
        state.lock.lock()
        state.queue.clear()
        state.listeners.removeAll()
        state.typingBurstDeadline = 0
        state.nextSequence = 0
        state.lastPresentedSequence = 0
        state.lastPresentedTime = 0
        state.emergencyDropCount = 0
        state.lock.unlock()
    }

    private func streamState(for streamID: StreamID) -> StreamState {
        stateLock.lock()
        if let existing = streams[streamID] {
            stateLock.unlock()
            return existing
        }

        let created = StreamState(capacity: defaultQueueCapacity)
        streams[streamID] = created
        stateLock.unlock()
        return created
    }

    private func streamStateIfPresent(for streamID: StreamID) -> StreamState? {
        stateLock.lock()
        let state = streams[streamID]
        stateLock.unlock()
        return state
    }

    private func oldestAgeMs(snapshot: MirageSPSCFrameQueue.Snapshot, now: CFAbsoluteTime) -> Double {
        guard let decodeTime = snapshot.oldestDecodeTime else { return 0 }
        return max(0, now - decodeTime) * 1000
    }

    private func typingBurstActiveLocked(state: StreamState, now: CFAbsoluteTime) -> Bool {
        guard state.typingBurstDeadline > 0 else { return false }
        if now < state.typingBurstDeadline {
            return true
        }
        state.typingBurstDeadline = 0
        return false
    }

    private func activeListenersLocked(state: StreamState) -> [@Sendable () -> Void] {
        var callbacks: [@Sendable () -> Void] = []
        callbacks.reserveCapacity(state.listeners.count)

        var staleKeys: [ObjectIdentifier] = []
        for (key, listener) in state.listeners {
            guard listener.owner.value != nil else {
                staleKeys.append(key)
                continue
            }
            callbacks.append(listener.callback)
        }

        if !staleKeys.isEmpty {
            for key in staleKeys {
                state.listeners.removeValue(forKey: key)
            }
        }

        return callbacks
    }
}
