//
//  MirageRenderStreamStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Per-stream render store with decode-health telemetry.
//

import CoreGraphics
import CoreMedia
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

    struct RenderTelemetrySnapshot: Sendable {
        let decodeFPS: Double
        let presentedFPS: Double
        let uniquePresentedFPS: Double
        let queueDepth: Int
        let decodeHealthy: Bool
        let severeDecodeUnderrun: Bool
        let targetFPS: Int
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
        var typingBurstDeadline: CFAbsoluteTime = 0
        var targetFPS: Int = 60
        var listeners: [ObjectIdentifier: FrameListener] = [:]

        var decodeSamples: [CFAbsoluteTime] = []
        var decodeSampleStartIndex: Int = 0
        var presentedSamples: [CFAbsoluteTime] = []
        var presentedSampleStartIndex: Int = 0
        var uniquePresentedSamples: [CFAbsoluteTime] = []
        var uniquePresentedSampleStartIndex: Int = 0

        init(capacity: Int) {
            queue = MirageSPSCFrameQueue(capacity: capacity)
        }
    }

    private let stateLock = NSLock()
    private var streams: [StreamID: StreamState] = [:]

    private let defaultQueueCapacity = 24
    private let typingBurstWindow: CFAbsoluteTime = 0.35
    private let sampleWindowSeconds: CFAbsoluteTime = 1.0

    private init() {}

    @discardableResult
    func enqueue(
        pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        presentationTime: CMTime,
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
            presentationTime: presentationTime,
            metalTexture: metalTexture,
            texture: texture
        )

        let pushResult = state.queue.enqueue(frame)
        let now = CFAbsoluteTimeGetCurrent()
        appendSampleLocked(
            now,
            samples: &state.decodeSamples,
            startIndex: &state.decodeSampleStartIndex
        )

        let snapshot = state.queue.snapshot()
        listeners = activeListenersLocked(state: state)
        result = EnqueueResult(
            sequence: frame.sequence,
            queueDepth: snapshot.depth,
            oldestAgeMs: oldestAgeMs(snapshot: snapshot, now: now),
            emergencyDrops: pushResult.dropped
        )
        state.lock.unlock()

        for callback in listeners {
            callback()
        }

        return result
    }

    func dequeue(for streamID: StreamID) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        let frame = state.queue.dequeue()
        state.lock.unlock()
        return frame
    }

    func dequeueForPresentation(
        for streamID: StreamID,
        policy: MirageRenderPresentationPolicy
    ) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }

        state.lock.lock()
        defer { state.lock.unlock() }

        let snapshot = state.queue.snapshot()
        guard snapshot.depth > 0 else { return nil }

        switch policy {
        case .latest:
            if snapshot.depth > 1 {
                _ = state.queue.trimNewest(keepDepth: 1)
            }
        case let .buffered(maxDepth):
            let clampedDepth = min(
                max(1, maxDepth),
                MirageRenderModePolicy.maxStressBufferDepth
            )
            if snapshot.depth > clampedDepth {
                _ = state.queue.trimNewest(keepDepth: clampedDepth)
            }
        }

        return state.queue.dequeue()
    }

    func peekLatest(for streamID: StreamID) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        let frame = state.queue.peekLatest()
        state.lock.unlock()
        return frame
    }

    func queueDepth(for streamID: StreamID) -> Int {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let depth = state.queue.snapshot().depth
        state.lock.unlock()
        return depth
    }

    func oldestAgeMs(for streamID: StreamID, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Double {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let snapshot = state.queue.snapshot()
        state.lock.unlock()
        return oldestAgeMs(snapshot: snapshot, now: now)
    }

    func latestSequence(for streamID: StreamID) -> UInt64 {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let sequence = state.queue.snapshot().latestSequence
        state.lock.unlock()
        return sequence
    }

    func markPresented(sequence: UInt64, for streamID: StreamID) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        appendSampleLocked(
            now,
            samples: &state.presentedSamples,
            startIndex: &state.presentedSampleStartIndex
        )
        guard sequence > state.lastPresentedSequence else {
            state.lock.unlock()
            return
        }

        state.lastPresentedSequence = sequence
        state.lastPresentedTime = now
        appendSampleLocked(
            now,
            samples: &state.uniquePresentedSamples,
            startIndex: &state.uniquePresentedSampleStartIndex
        )
        state.lock.unlock()
    }

    func presentationSnapshot(for streamID: StreamID) -> PresentationSnapshot {
        guard let state = streamStateIfPresent(for: streamID) else {
            return PresentationSnapshot(sequence: 0, presentedTime: 0)
        }

        state.lock.lock()
        let snapshot = PresentationSnapshot(
            sequence: state.lastPresentedSequence,
            presentedTime: state.lastPresentedTime
        )
        state.lock.unlock()
        return snapshot
    }

    func renderTelemetrySnapshot(
        for streamID: StreamID,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> RenderTelemetrySnapshot {
        guard let state = streamStateIfPresent(for: streamID) else {
            return RenderTelemetrySnapshot(
                decodeFPS: 0,
                presentedFPS: 0,
                uniquePresentedFPS: 0,
                queueDepth: 0,
                decodeHealthy: true,
                severeDecodeUnderrun: false,
                targetFPS: 60
            )
        }

        state.lock.lock()
        trimSamplesLocked(
            now: now,
            samples: &state.decodeSamples,
            startIndex: &state.decodeSampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.presentedSamples,
            startIndex: &state.presentedSampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.uniquePresentedSamples,
            startIndex: &state.uniquePresentedSampleStartIndex
        )

        let decodeFPS = Double(state.decodeSamples.count - state.decodeSampleStartIndex)
        let presentedFPS = Double(state.presentedSamples.count - state.presentedSampleStartIndex)
        let uniquePresentedFPS = Double(state.uniquePresentedSamples.count - state.uniquePresentedSampleStartIndex)
        let queueDepth = state.queue.snapshot().depth
        let targetFPS = max(1, state.targetFPS)
        let decodeRatio = decodeFPS / Double(targetFPS)
        let decodeHealthy = decodeRatio >= MirageRenderModePolicy.healthyDecodeRatio
        let severeDecodeUnderrun = decodeRatio < MirageRenderModePolicy.stressedDecodeRatio
        state.lock.unlock()

        return RenderTelemetrySnapshot(
            decodeFPS: decodeFPS,
            presentedFPS: presentedFPS,
            uniquePresentedFPS: uniquePresentedFPS,
            queueDepth: queueDepth,
            decodeHealthy: decodeHealthy,
            severeDecodeUnderrun: severeDecodeUnderrun,
            targetFPS: targetFPS
        )
    }

    func setTargetFPS(for streamID: StreamID, targetFPS: Int) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.targetFPS = MirageRenderModePolicy.normalizedTargetFPS(targetFPS)
        state.lock.unlock()
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
        state.decodeSamples.removeAll(keepingCapacity: false)
        state.decodeSampleStartIndex = 0
        state.presentedSamples.removeAll(keepingCapacity: false)
        state.presentedSampleStartIndex = 0
        state.uniquePresentedSamples.removeAll(keepingCapacity: false)
        state.uniquePresentedSampleStartIndex = 0
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

    private func appendSampleLocked(
        _ now: CFAbsoluteTime,
        samples: inout [CFAbsoluteTime],
        startIndex: inout Int
    ) {
        samples.append(now)
        trimSamplesLocked(now: now, samples: &samples, startIndex: &startIndex)
    }

    private func trimSamplesLocked(
        now: CFAbsoluteTime,
        samples: inout [CFAbsoluteTime],
        startIndex: inout Int
    ) {
        let cutoff = now - sampleWindowSeconds
        while startIndex < samples.count, samples[startIndex] < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }
}
