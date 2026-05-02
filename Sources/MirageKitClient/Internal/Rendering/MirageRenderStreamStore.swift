//
//  MirageRenderStreamStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Latest-frame render store with submission telemetry.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MirageKit

final class MirageRenderStreamStore: @unchecked Sendable {
    struct EnqueueResult: Sendable {
        let sequence: UInt64
        let pendingFrameCount: Int
        let pendingFrameAgeMs: Double
        let overwrittenPendingFrames: Int
    }

    struct SubmissionSnapshot: Sendable {
        let sequence: UInt64
        let submittedTime: CFAbsoluteTime
        let mappedPresentationTime: CMTime
    }

    struct RenderTelemetrySnapshot: Sendable {
        let decodeFPS: Double
        let submittedFPS: Double
        let uniqueSubmittedFPS: Double
        let pendingFrameCount: Int
        let pendingFrameAgeMs: Double
        let overwrittenPendingFrames: UInt64
        let displayLayerNotReadyCount: UInt64
        let presentationStallCount: UInt64
        let worstPresentationGapMs: Double
        let frameIntervalP95Ms: Double
        let frameIntervalP99Ms: Double
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
        var pendingFrame: MirageRenderFrame?
        var nextSequence: UInt64 = 0
        var lastSubmittedSequence: UInt64 = 0
        var lastSubmittedTime: CFAbsoluteTime = 0
        var lastSubmittedMappedPresentationTime: CMTime = .invalid
        var targetFPS: Int = 60
        var listeners: [ObjectIdentifier: FrameListener] = [:]
        var presentationRecoveryHandlers: [ObjectIdentifier: FrameListener] = [:]

        var decodeSamples: [CFAbsoluteTime] = []
        var decodeSampleStartIndex: Int = 0
        var submittedSamples: [CFAbsoluteTime] = []
        var submittedSampleStartIndex: Int = 0
        var uniqueSubmittedSamples: [CFAbsoluteTime] = []
        var uniqueSubmittedSampleStartIndex: Int = 0
        var frameIntervalSamples: [(time: CFAbsoluteTime, intervalMs: Double)] = []
        var frameIntervalSampleStartIndex: Int = 0

        var overwrittenPendingFramesSinceLastSnapshot: UInt64 = 0
        var displayLayerNotReadyCountSinceLastSnapshot: UInt64 = 0
        var presentationStallCountSinceLastSnapshot: UInt64 = 0
        var worstPresentationGapMsSinceLastSnapshot: Double = 0
    }

    private let stateLock = NSLock()
    private var streams: [StreamID: StreamState] = [:]
    private let sampleWindowSeconds: CFAbsoluteTime = 1.0
    private let smoothnessWindowSeconds: CFAbsoluteTime = 30.0
    private let presentationStallThresholdMs: Double = 500

    private init() {}

    @discardableResult
    func enqueue(
        pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        presentationTime: CMTime,
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
            presentationTime: presentationTime
        )
        let overwrotePendingFrame = state.pendingFrame != nil ? 1 : 0
        state.pendingFrame = frame
        let now = CFAbsoluteTimeGetCurrent()
        appendSampleLocked(now, samples: &state.decodeSamples, startIndex: &state.decodeSampleStartIndex)
        if overwrotePendingFrame > 0 {
            state.overwrittenPendingFramesSinceLastSnapshot &+= UInt64(overwrotePendingFrame)
        }
        listeners = activeListenersLocked(state: state)
        result = EnqueueResult(
            sequence: frame.sequence,
            pendingFrameCount: 1,
            pendingFrameAgeMs: pendingFrameAgeMsLocked(state: state, now: now),
            overwrittenPendingFrames: overwrotePendingFrame
        )
        state.lock.unlock()

        for callback in listeners {
            callback()
        }

        return result
    }

    func takePendingFrame(for streamID: StreamID) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        defer { state.lock.unlock() }

        guard let pendingFrame = state.pendingFrame else { return nil }
        guard pendingFrame.sequence > state.lastSubmittedSequence else {
            state.pendingFrame = nil
            return nil
        }

        state.pendingFrame = nil
        return pendingFrame
    }

    func peekPendingFrame(for streamID: StreamID) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        let frame = state.pendingFrame
        state.lock.unlock()
        return frame
    }

    func pendingFrameCount(for streamID: StreamID) -> Int {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let count = state.pendingFrame == nil ? 0 : 1
        state.lock.unlock()
        return count
    }

    func pendingFrameAgeMs(for streamID: StreamID, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Double {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let age = pendingFrameAgeMsLocked(state: state, now: now)
        state.lock.unlock()
        return age
    }

    func latestSequence(for streamID: StreamID) -> UInt64 {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let sequence = state.nextSequence
        state.lock.unlock()
        return sequence
    }

    func markSubmitted(
        sequence: UInt64,
        mappedPresentationTime: CMTime,
        for streamID: StreamID
    ) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        appendSampleLocked(now, samples: &state.submittedSamples, startIndex: &state.submittedSampleStartIndex)
        guard sequence > state.lastSubmittedSequence else {
            state.lock.unlock()
            return
        }

        let previousSubmittedTime = state.lastSubmittedTime
        if previousSubmittedTime > 0 {
            let intervalMs = max(0, now - previousSubmittedTime) * 1000
            appendFrameIntervalSampleLocked(
                time: now,
                intervalMs: intervalMs,
                samples: &state.frameIntervalSamples,
                startIndex: &state.frameIntervalSampleStartIndex
            )
            if intervalMs >= presentationStallThresholdMs {
                state.presentationStallCountSinceLastSnapshot &+= 1
                state.worstPresentationGapMsSinceLastSnapshot = max(
                    state.worstPresentationGapMsSinceLastSnapshot,
                    intervalMs
                )
            }
        }

        state.lastSubmittedSequence = sequence
        state.lastSubmittedTime = now
        state.lastSubmittedMappedPresentationTime = mappedPresentationTime
        appendSampleLocked(
            now,
            samples: &state.uniqueSubmittedSamples,
            startIndex: &state.uniqueSubmittedSampleStartIndex
        )
        state.lock.unlock()
    }

    func submissionSnapshot(for streamID: StreamID) -> SubmissionSnapshot {
        guard let state = streamStateIfPresent(for: streamID) else {
            return SubmissionSnapshot(sequence: 0, submittedTime: 0, mappedPresentationTime: .invalid)
        }

        state.lock.lock()
        let snapshot = SubmissionSnapshot(
            sequence: state.lastSubmittedSequence,
            submittedTime: state.lastSubmittedTime,
            mappedPresentationTime: state.lastSubmittedMappedPresentationTime
        )
        state.lock.unlock()
        return snapshot
    }

    func noteDisplayLayerNotReady(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.displayLayerNotReadyCountSinceLastSnapshot &+= 1
        state.lock.unlock()
    }

    func renderTelemetrySnapshot(
        for streamID: StreamID,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> RenderTelemetrySnapshot {
        guard let state = streamStateIfPresent(for: streamID) else {
            return RenderTelemetrySnapshot(
                decodeFPS: 0,
                submittedFPS: 0,
                uniqueSubmittedFPS: 0,
                pendingFrameCount: 0,
                pendingFrameAgeMs: 0,
                overwrittenPendingFrames: 0,
                displayLayerNotReadyCount: 0,
                presentationStallCount: 0,
                worstPresentationGapMs: 0,
                frameIntervalP95Ms: 0,
                frameIntervalP99Ms: 0,
                decodeHealthy: true,
                severeDecodeUnderrun: false,
                targetFPS: 60
            )
        }

        state.lock.lock()
        trimSamplesLocked(now: now, samples: &state.decodeSamples, startIndex: &state.decodeSampleStartIndex)
        trimSamplesLocked(now: now, samples: &state.submittedSamples, startIndex: &state.submittedSampleStartIndex)
        trimSamplesLocked(
            now: now,
            samples: &state.uniqueSubmittedSamples,
            startIndex: &state.uniqueSubmittedSampleStartIndex
        )
        trimFrameIntervalSamplesLocked(
            now: now,
            samples: &state.frameIntervalSamples,
            startIndex: &state.frameIntervalSampleStartIndex
        )

        let decodeFPS = Double(state.decodeSamples.count - state.decodeSampleStartIndex)
        let submittedFPS = Double(state.submittedSamples.count - state.submittedSampleStartIndex)
        let uniqueSubmittedFPS = Double(state.uniqueSubmittedSamples.count - state.uniqueSubmittedSampleStartIndex)
        let pendingFrameCount = state.pendingFrame == nil ? 0 : 1
        let pendingFrameAgeMs = pendingFrameAgeMsLocked(state: state, now: now)
        let overwrittenPendingFrames = state.overwrittenPendingFramesSinceLastSnapshot
        let displayLayerNotReadyCount = state.displayLayerNotReadyCountSinceLastSnapshot
        let presentationStallCount = state.presentationStallCountSinceLastSnapshot
        let worstPresentationGapMs = state.worstPresentationGapMsSinceLastSnapshot
        let intervalSamples = Array(state.frameIntervalSamples[state.frameIntervalSampleStartIndex...].map(\.intervalMs))
        let frameIntervalP95Ms = percentile(intervalSamples, percentile: 0.95)
        let frameIntervalP99Ms = percentile(intervalSamples, percentile: 0.99)
        state.overwrittenPendingFramesSinceLastSnapshot = 0
        state.displayLayerNotReadyCountSinceLastSnapshot = 0
        state.presentationStallCountSinceLastSnapshot = 0
        state.worstPresentationGapMsSinceLastSnapshot = 0

        let targetFPS = max(1, state.targetFPS)
        let decodeRatio = decodeFPS / Double(targetFPS)
        let decodeHealthy = decodeRatio >= MirageRenderModePolicy.healthyDecodeRatio
        let severeDecodeUnderrun = decodeRatio < MirageRenderModePolicy.stressedDecodeRatio
        state.lock.unlock()

        return RenderTelemetrySnapshot(
            decodeFPS: decodeFPS,
            submittedFPS: submittedFPS,
            uniqueSubmittedFPS: uniqueSubmittedFPS,
            pendingFrameCount: pendingFrameCount,
            pendingFrameAgeMs: pendingFrameAgeMs,
            overwrittenPendingFrames: overwrittenPendingFrames,
            displayLayerNotReadyCount: displayLayerNotReadyCount,
            presentationStallCount: presentationStallCount,
            worstPresentationGapMs: worstPresentationGapMs,
            frameIntervalP95Ms: frameIntervalP95Ms,
            frameIntervalP99Ms: frameIntervalP99Ms,
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

    func registerPresentationRecoveryHandler(
        for streamID: StreamID,
        owner: AnyObject,
        callback: @escaping @Sendable () -> Void
    ) {
        let state = streamState(for: streamID)
        state.lock.lock()
        let key = ObjectIdentifier(owner)
        state.presentationRecoveryHandlers[key] = FrameListener(owner: WeakOwner(owner), callback: callback)
        state.lock.unlock()
    }

    func unregisterPresentationRecoveryHandler(for streamID: StreamID, owner: AnyObject) {
        guard let state = streamStateIfPresent(for: streamID) else { return }
        state.lock.lock()
        state.presentationRecoveryHandlers.removeValue(forKey: ObjectIdentifier(owner))
        state.lock.unlock()
    }

    @discardableResult
    func requestPresentationRecovery(for streamID: StreamID) -> Bool {
        guard let state = streamStateIfPresent(for: streamID) else { return false }

        state.lock.lock()
        let callbacks = activePresentationRecoveryHandlersLocked(state: state)
        state.lock.unlock()

        for callback in callbacks {
            callback()
        }

        return !callbacks.isEmpty
    }

    func clear(for streamID: StreamID) {
        stateLock.lock()
        let state = streams[streamID]

        guard let state else {
            stateLock.unlock()
            return
        }
        state.lock.lock()
        state.pendingFrame = nil
        state.nextSequence = 0
        state.lastSubmittedSequence = 0
        state.lastSubmittedTime = 0
        state.lastSubmittedMappedPresentationTime = .invalid
        state.decodeSamples.removeAll(keepingCapacity: false)
        state.decodeSampleStartIndex = 0
        state.submittedSamples.removeAll(keepingCapacity: false)
        state.submittedSampleStartIndex = 0
        state.uniqueSubmittedSamples.removeAll(keepingCapacity: false)
        state.uniqueSubmittedSampleStartIndex = 0
        state.frameIntervalSamples.removeAll(keepingCapacity: false)
        state.frameIntervalSampleStartIndex = 0
        state.overwrittenPendingFramesSinceLastSnapshot = 0
        state.displayLayerNotReadyCountSinceLastSnapshot = 0
        state.presentationStallCountSinceLastSnapshot = 0
        state.worstPresentationGapMsSinceLastSnapshot = 0
        state.listeners = state.listeners.filter { _, listener in
            listener.owner.value != nil
        }
        state.presentationRecoveryHandlers = state.presentationRecoveryHandlers.filter { _, listener in
            listener.owner.value != nil
        }
        if state.listeners.isEmpty, state.presentationRecoveryHandlers.isEmpty {
            streams.removeValue(forKey: streamID)
        }
        state.lock.unlock()
        stateLock.unlock()
    }

    private func streamState(for streamID: StreamID) -> StreamState {
        stateLock.lock()
        if let existing = streams[streamID] {
            stateLock.unlock()
            return existing
        }

        let created = StreamState()
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

    private func activePresentationRecoveryHandlersLocked(state: StreamState) -> [@Sendable () -> Void] {
        var callbacks: [@Sendable () -> Void] = []
        callbacks.reserveCapacity(state.presentationRecoveryHandlers.count)

        var staleKeys: [ObjectIdentifier] = []
        for (key, listener) in state.presentationRecoveryHandlers {
            guard listener.owner.value != nil else {
                staleKeys.append(key)
                continue
            }
            callbacks.append(listener.callback)
        }

        if !staleKeys.isEmpty {
            for key in staleKeys {
                state.presentationRecoveryHandlers.removeValue(forKey: key)
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

    private func appendFrameIntervalSampleLocked(
        time: CFAbsoluteTime,
        intervalMs: Double,
        samples: inout [(time: CFAbsoluteTime, intervalMs: Double)],
        startIndex: inout Int
    ) {
        samples.append((time: time, intervalMs: intervalMs))
        trimFrameIntervalSamplesLocked(now: time, samples: &samples, startIndex: &startIndex)
    }

    private func trimFrameIntervalSamplesLocked(
        now: CFAbsoluteTime,
        samples: inout [(time: CFAbsoluteTime, intervalMs: Double)],
        startIndex: inout Int
    ) {
        let cutoff = now - smoothnessWindowSeconds
        while startIndex < samples.count, samples[startIndex].time < cutoff {
            startIndex += 1
        }
        if startIndex > 256 {
            samples.removeFirst(startIndex)
            startIndex = 0
        }
    }

    private func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clampedPercentile = min(max(percentile, 0), 1)
        let index = Int((Double(sorted.count - 1) * clampedPercentile).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private func pendingFrameAgeMsLocked(state: StreamState, now: CFAbsoluteTime) -> Double {
        guard let decodeTime = state.pendingFrame?.decodeTime else { return 0 }
        return max(0, now - decodeTime) * 1000
    }
}
