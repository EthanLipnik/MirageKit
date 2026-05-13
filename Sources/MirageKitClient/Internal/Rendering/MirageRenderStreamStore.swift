//
//  MirageRenderStreamStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Latest-frame render store with submission telemetry.
//

import CoreMedia
import CoreVideo
import Foundation
import MirageKit

/// Thread-safe per-stream frame queue and presentation telemetry store.
///
/// Decoders enqueue frames here from stream-specific tasks while SwiftUI/AppKit
/// render surfaces consume frames on display ticks. The store also aggregates the
/// submission, display, and smoothness counters that drive receiver health and
/// runtime workload decisions.
final class MirageRenderStreamStore: @unchecked Sendable {
    /// Rolling window for per-stream render throughput samples.
    static let sampleWindowSeconds: CFAbsoluteTime = 1.0

    /// Rolling window for presentation smoothness metrics.
    static let smoothnessWindowSeconds: CFAbsoluteTime = 30.0

    /// Presentation gap threshold counted as a render stall.
    static let presentationStallThresholdMs: Double = 500

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

    /// Returns the next frame that should be submitted after the given sequence.
    ///
    /// Older frames are discarded and counted as late/coalesced when playout delay
    /// requires keeping only a small amount of buffered presentation slack.
    func frameForPresentation(for streamID: StreamID, after submittedSequence: UInt64) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        defer { state.lock.unlock() }

        guard !state.pendingFrames.isEmpty else { return nil }
        var droppedLateFrames = 0
        while let first = state.pendingFrames.first, first.sequence <= submittedSequence {
            state.pendingFrames.removeFirst()
        }
        guard !state.pendingFrames.isEmpty else {
            return nil
        }

        let targetDelayFrames = min(max(state.playoutDelayFrames, 0), 2)
        let desiredCandidateDepthAfterSelection = targetDelayFrames + 1
        while state.pendingFrames.count > desiredCandidateDepthAfterSelection {
            state.pendingFrames.removeFirst()
            droppedLateFrames += 1
        }
        if droppedLateFrames > 0 {
            state.lateFrameDropsSinceLastSnapshot &+= UInt64(droppedLateFrames)
            state.coalescedFramesSinceLastSnapshot &+= UInt64(droppedLateFrames)
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

    /// Returns whether the stream has a queued frame newer than the submitted sequence.
    func hasFrameForPresentation(for streamID: StreamID, after submittedSequence: UInt64) -> Bool {
        guard let state = streamStateIfPresent(for: streamID) else { return false }
        state.lock.lock()
        let hasFrame = state.pendingFrames.contains { $0.sequence > submittedSequence }
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

    /// Returns the latest decoded-frame sequence number for the stream.
    func latestSequence(for streamID: StreamID) -> UInt64 {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let sequence = state.nextSequence
        state.lock.unlock()
        return sequence
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
        recordOverwrittenPendingFramesLocked(
            removePendingFramesOverCapacityLocked(state: state),
            state: state
        )
    }

    private func trimPendingFramesToCapacityLocked(state: MirageRenderStreamState) -> Int {
        let overwrittenPendingFrames = removePendingFramesOverCapacityLocked(state: state)
        recordOverwrittenPendingFramesLocked(overwrittenPendingFrames, state: state)
        return overwrittenPendingFrames
    }

    private func removePendingFramesOverCapacityLocked(state: MirageRenderStreamState) -> Int {
        var overwrittenPendingFrames = 0
        let pendingFrameCapacity = max(1, state.playoutDelayFrames + 1)
        while state.pendingFrames.count > pendingFrameCapacity {
            state.pendingFrames.removeFirst()
            overwrittenPendingFrames += 1
        }
        return overwrittenPendingFrames
    }

    private func recordOverwrittenPendingFramesLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.overwrittenPendingFramesSinceLastSnapshot &+= UInt64(count)
        state.coalescedFramesSinceLastSnapshot &+= UInt64(count)
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
