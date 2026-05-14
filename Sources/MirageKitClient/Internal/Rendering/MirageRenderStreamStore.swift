//
//  MirageRenderStreamStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Latency-mode render store with submission telemetry.
//

import CoreMedia
import CoreVideo
import Foundation
import MirageKit

/// Thread-safe per-stream frame queue and presentation telemetry store.
///
/// Decoders enqueue frames here from stream-specific tasks while SwiftUI/AppKit
/// render surfaces consume frames on display ticks. Lowest latency coalesces to
/// the newest decoded frame; Smoothest preserves ordered frames behind the
/// display clock until the local playout queue exceeds bounded age or depth.
final class MirageRenderStreamStore: @unchecked Sendable {
    /// Rolling window for per-stream render throughput samples.
    static let sampleWindowSeconds: CFAbsoluteTime = 1.0

    /// Rolling window for presentation smoothness metrics.
    static let smoothnessWindowSeconds: CFAbsoluteTime = 30.0

    /// Presentation gap threshold counted as a render stall.
    static let presentationStallThresholdMs: Double = 500

    private static let smoothestQueueCapacity = 4
    private static let smoothestMinimumQueueAgeLimitMs: Double = 100
    private static let smoothestQueueAgeLimitFrames: Double = 6

    /// Shared store used by all active client render streams.
    static let shared = MirageRenderStreamStore()

    private let stateLock = NSLock()
    private var streams: [StreamID: MirageRenderStreamState] = [:]

    private init() {}

    /// Adds a decoded frame to the stream queue and notifies active listeners.
    ///
    /// - Returns: The number of pending frames overwritten to keep the queue bounded.
    func enqueue(
        pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        presentationTime: CMTime,
        remotePresentationTime: CMTime = .invalid,
        for streamID: StreamID
    ) -> Int {
        let state = streamState(for: streamID)
        let listeners: [@Sendable () -> Void]
        let overwrittenPendingFrames: Int

        state.lock.lock()
        state.nextSequence &+= 1
        let frame = MirageRenderFrame(
            pixelBuffer: pixelBuffer,
            contentRect: contentRect,
            sequence: state.nextSequence,
            generation: state.generation,
            decodeTime: decodeTime,
            presentationTime: presentationTime,
            remotePresentationTime: remotePresentationTime
        )
        state.pendingFrames.append(frame)
        overwrittenPendingFrames = trimPendingFramesToCapacityLocked(state: state)
        let now = CFAbsoluteTimeGetCurrent()
        appendSampleLocked(now, samples: &state.decodeSamples, startIndex: &state.decodeSampleStartIndex)
        listeners = activeListenersLocked(state: state)
        state.lock.unlock()

        for callback in listeners {
            callback()
        }

        return overwrittenPendingFrames
    }

    func enqueue(
        pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        presentationTime: CMTime,
        remotePresentationTime: CMTime = .invalid,
        generation: UInt64,
        hostEpoch: UInt16?,
        dimensionToken: UInt16?,
        frameNumber: UInt32?,
        queueEpoch: UInt64?,
        timeline: FrameTimeline?,
        for streamID: StreamID
    ) -> MirageRenderEnqueueResult {
        let state = streamState(for: streamID)
        let listeners: [@Sendable () -> Void]
        let result: MirageRenderEnqueueResult

        state.lock.lock()
        state.nextSequence &+= 1
        let frame = MirageRenderFrame(
            pixelBuffer: pixelBuffer,
            contentRect: contentRect,
            sequence: state.nextSequence,
            generation: generation,
            decodeTime: decodeTime,
            presentationTime: presentationTime,
            remotePresentationTime: remotePresentationTime,
            hostEpoch: hostEpoch,
            dimensionToken: dimensionToken,
            frameNumber: frameNumber,
            queueEpoch: queueEpoch,
            timeline: timeline?.markingRenderEnqueued(
                at: decodeTime,
                queueAgeMs: max(0, CFAbsoluteTimeGetCurrent() - decodeTime) * 1000
            )
        )
        state.pendingFrames.append(frame)
        let overwrittenPendingFrames = trimPendingFramesToCapacityLocked(state: state)
        let now = CFAbsoluteTimeGetCurrent()
        appendSampleLocked(now, samples: &state.decodeSamples, startIndex: &state.decodeSampleStartIndex)
        listeners = activeListenersLocked(state: state)
        result = MirageRenderEnqueueResult(
            cursor: frame.cursor,
            didEnqueue: true,
            pendingFrameCount: state.pendingFrames.count,
            pendingFrameAgeMs: pendingFrameAgeMsLocked(state: state, now: now),
            overwrittenPendingFrames: overwrittenPendingFrames
        )
        state.lock.unlock()

        for callback in listeners {
            callback()
        }

        return result
    }

    /// Returns the next frame that should be submitted after the given generation-aware cursor.
    ///
    /// Lowest latency coalesces to the newest decoded frame. Smoothest returns
    /// the next ordered frame unless the local queue has aged past a long-gap
    /// recovery threshold.
    func frameForPresentation(for streamID: StreamID, after submittedCursor: MirageRenderCursor) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        defer { state.lock.unlock() }

        guard !state.pendingFrames.isEmpty else { return nil }
        var droppedLateFrames = 0
        while let first = state.pendingFrames.first, !first.cursor.isAfter(submittedCursor) {
            state.pendingFrames.removeFirst()
        }
        guard !state.pendingFrames.isEmpty else {
            return nil
        }

        switch state.latencyMode {
        case .lowestLatency:
            while state.pendingFrames.count > 1 {
                state.pendingFrames.removeFirst()
                droppedLateFrames += 1
            }
            if droppedLateFrames > 0 {
                state.lateFrameDropsSinceLastSnapshot &+= UInt64(droppedLateFrames)
                state.coalescedFramesSinceLastSnapshot &+= UInt64(droppedLateFrames)
            }
        case .smoothest:
            let smoothestDrops = removeSmoothestExpiredFramesLocked(
                state: state,
                now: CFAbsoluteTimeGetCurrent()
            )
            recordSmoothestQueueDropsLocked(smoothestDrops, state: state)
        }

        return state.pendingFrames.first
    }

    /// Records timestamp correction diagnostics for the next telemetry snapshot.
    func recordFrameTimingDiagnostics(
        for streamID: StreamID,
        duplicateRemoteTimestamp: Bool,
        correctedStreamTimestamp: Bool
    ) {
        guard duplicateRemoteTimestamp || correctedStreamTimestamp else { return }
        let state = streamState(for: streamID)
        state.lock.lock()
        if duplicateRemoteTimestamp {
            state.duplicateRemoteTimestampsSinceLastSnapshot &+= 1
        }
        if correctedStreamTimestamp {
            state.correctedStreamTimestampsSinceLastSnapshot &+= 1
        }
        state.lock.unlock()
    }

    /// Returns whether the stream has a queued frame newer than the submitted cursor.
    func hasFrameForPresentation(for streamID: StreamID, after submittedCursor: MirageRenderCursor) -> Bool {
        guard let state = streamStateIfPresent(for: streamID) else { return false }
        state.lock.lock()
        let hasFrame = state.pendingFrames.contains { $0.cursor.isAfter(submittedCursor) }
        state.lock.unlock()
        return hasFrame
    }

    /// Returns the number of queued frames waiting for presentation.
    func pendingFrameCount(for streamID: StreamID) -> Int {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let count = state.pendingFrames.count
        state.lock.unlock()
        return count
    }

    /// Drops queued frames for a stream and returns how many were removed.
    func clearPendingFrames(for streamID: StreamID) -> Int {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let count = state.pendingFrames.count
        state.pendingFrames.removeAll(keepingCapacity: false)
        state.lock.unlock()
        return count
    }

    /// Returns the latest decoded-frame cursor for the stream.
    func latestCursor(for streamID: StreamID) -> MirageRenderCursor {
        guard let state = streamStateIfPresent(for: streamID) else { return .zero }
        state.lock.lock()
        let cursor = MirageRenderCursor(generation: state.generation, sequence: state.nextSequence)
        state.lock.unlock()
        return cursor
    }

    func currentGeneration(for streamID: StreamID) -> UInt64 {
        let state = streamState(for: streamID)
        state.lock.lock()
        let generation = state.generation
        state.lock.unlock()
        return generation
    }

    func latestAcceptedFrameTimeline(for streamID: StreamID) -> FrameTimeline? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        let timeline = state.lastAcceptedFrameTimeline
        state.lock.unlock()
        return timeline
    }

    func presentationTiming(for streamID: StreamID) -> MirageRenderPresentationTiming {
        let state = streamState(for: streamID)
        state.lock.lock()
        let timing = MirageRenderPresentationTiming(
            targetFPS: state.sourceTargetFPS,
            playoutDelayFrames: state.playoutDelayFrames
        )
        state.lock.unlock()
        return timing
    }

    func setCadenceTarget(for streamID: StreamID, target: MirageStreamCadenceTarget) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.sourceTargetFPS = target.sourceFPS
        state.displayTargetFPS = target.displayFPS
        state.latencyMode = target.latencyMode
        state.playoutDelayFrames = target.playoutDelayFrames
        trimPendingFramesToCurrentCapacityLocked(state: state)
        state.lock.unlock()
    }

    func setDisplayTargetFPS(for streamID: StreamID, displayFPS: Int) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.displayTargetFPS = MirageRenderModePolicy.normalizedTargetFPS(displayFPS)
        state.lock.unlock()
    }

    func setLatencyMode(for streamID: StreamID, latencyMode: MirageStreamLatencyMode) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.latencyMode = latencyMode
        state.playoutDelayFrames = MirageStreamCadenceTarget.playoutDelayFrames(for: latencyMode)
        trimPendingFramesToCurrentCapacityLocked(state: state)
        state.lock.unlock()
    }

    func clear(for streamID: StreamID) {
        stateLock.lock()
        let state = streams[streamID]

        guard let state else {
            stateLock.unlock()
            return
        }
        state.lock.lock()
        state.resetFramesAndTelemetryLocked()
        if state.listeners.isEmpty, state.presentationRecoveryHandlers.isEmpty {
            streams.removeValue(forKey: streamID)
        }
        state.lock.unlock()
        stateLock.unlock()
    }
}

extension MirageRenderStreamStore {
    func streamState(for streamID: StreamID) -> MirageRenderStreamState {
        stateLock.lock()
        if let existing = streams[streamID] {
            stateLock.unlock()
            return existing
        }

        let created = MirageRenderStreamState()
        streams[streamID] = created
        stateLock.unlock()
        return created
    }

    func streamStateIfPresent(for streamID: StreamID) -> MirageRenderStreamState? {
        stateLock.lock()
        let state = streams[streamID]
        stateLock.unlock()
        return state
    }

    func activeListenersLocked(state: MirageRenderStreamState) -> [@Sendable () -> Void] {
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

    private func trimPendingFramesToCurrentCapacityLocked(state: MirageRenderStreamState) {
        let result = removePendingFramesOverCapacityLocked(state: state)
        recordPendingFrameTrimLocked(result, state: state)
    }

    private func trimPendingFramesToCapacityLocked(state: MirageRenderStreamState) -> Int {
        let result = removePendingFramesOverCapacityLocked(state: state)
        recordPendingFrameTrimLocked(result, state: state)
        return result.overwrittenPendingFrames
    }

    private func removePendingFramesOverCapacityLocked(
        state: MirageRenderStreamState
    ) -> PendingFrameTrimResult {
        var removedFrames = 0
        let pendingFrameCapacity = pendingFrameCapacityLocked(state: state)
        while state.pendingFrames.count > pendingFrameCapacity {
            state.pendingFrames.removeFirst()
            removedFrames += 1
        }

        switch state.latencyMode {
        case .lowestLatency:
            return PendingFrameTrimResult(overwrittenPendingFrames: removedFrames, smoothestQueueDrops: 0)
        case .smoothest:
            return PendingFrameTrimResult(overwrittenPendingFrames: 0, smoothestQueueDrops: removedFrames)
        }
    }

    private func pendingFrameCapacityLocked(state: MirageRenderStreamState) -> Int {
        switch state.latencyMode {
        case .lowestLatency:
            1
        case .smoothest:
            Self.smoothestQueueCapacity
        }
    }

    private func removeSmoothestExpiredFramesLocked(
        state: MirageRenderStreamState,
        now: CFAbsoluteTime
    ) -> Int {
        guard state.latencyMode == .smoothest else { return 0 }
        var droppedFrames = 0
        let maxAgeMs = smoothestQueueAgeLimitMsLocked(state: state)
        while state.pendingFrames.count > 1,
              let first = state.pendingFrames.first,
              let ageMs = comparableFrameAgeMs(first, now: now),
              ageMs > maxAgeMs {
            state.pendingFrames.removeFirst()
            droppedFrames += 1
        }
        return droppedFrames
    }

    private func smoothestQueueAgeLimitMsLocked(state: MirageRenderStreamState) -> Double {
        let frameBudgetMs = 1000.0 / Double(max(1, state.sourceTargetFPS))
        return max(Self.smoothestMinimumQueueAgeLimitMs, frameBudgetMs * Self.smoothestQueueAgeLimitFrames)
    }

    private func comparableFrameAgeMs(_ frame: MirageRenderFrame, now: CFAbsoluteTime) -> Double? {
        let ageSeconds = now - frame.decodeTime
        guard ageSeconds >= 0, ageSeconds < 60 else { return nil }
        return ageSeconds * 1000
    }

    private func recordPendingFrameTrimLocked(
        _ result: PendingFrameTrimResult,
        state: MirageRenderStreamState
    ) {
        recordOverwrittenPendingFramesLocked(result.overwrittenPendingFrames, state: state)
        recordSmoothestQueueDropsLocked(result.smoothestQueueDrops, state: state)
    }

    private func recordOverwrittenPendingFramesLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.overwrittenPendingFramesSinceLastSnapshot &+= UInt64(count)
        state.coalescedFramesSinceLastSnapshot &+= UInt64(count)
    }

    private func recordSmoothestQueueDropsLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.smoothestQueueDropsSinceLastSnapshot &+= UInt64(count)
    }

    func activePresentationRecoveryHandlersLocked(state: MirageRenderStreamState) -> [@Sendable () -> Void] {
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
}

private struct PendingFrameTrimResult {
    let overwrittenPendingFrames: Int
    let smoothestQueueDrops: Int
}
