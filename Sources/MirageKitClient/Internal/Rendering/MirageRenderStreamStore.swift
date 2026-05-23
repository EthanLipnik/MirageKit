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
/// the newest decoded frame; Smoothest presents ordered frames with a small
/// timed playout buffer, dropping stale backlog when age or depth bounds are
/// exceeded.
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
        let now = CFAbsoluteTimeGetCurrent()
        let trimResult = state.presentationController.enqueue(
            frame,
            into: &state.pendingFrames,
            policy: presentationLatencyPolicyLocked(state: state, now: now),
            now: now
        )
        recordPendingFrameTrimLocked(trimResult, state: state)
        overwrittenPendingFrames = trimResult.overwrittenPendingFrames
        appendSampleLocked(now, samples: &state.decodeSamples, startIndex: &state.decodeSampleStartIndex)
        recordPendingQueueSampleLocked(state: state, now: now)
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
        let now = CFAbsoluteTimeGetCurrent()
        resetPresentationEpochIfMetadataChangedLocked(
            state: state,
            hostEpoch: hostEpoch,
            dimensionToken: dimensionToken,
            now: now
        )
        let trimResult = state.presentationController.enqueue(
            frame,
            into: &state.pendingFrames,
            policy: presentationLatencyPolicyLocked(state: state, now: now),
            now: now
        )
        recordPendingFrameTrimLocked(trimResult, state: state)
        let overwrittenPendingFrames = trimResult.overwrittenPendingFrames
        appendSampleLocked(now, samples: &state.decodeSamples, startIndex: &state.decodeSampleStartIndex)
        recordPendingQueueSampleLocked(state: state, now: now)
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
    /// the next ordered frame unless the local queue has aged past the stale
    /// backlog recovery threshold.
    func frameForPresentation(for streamID: StreamID, after submittedCursor: MirageRenderCursor) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        defer { state.lock.unlock() }

        guard !state.pendingFrames.isEmpty else { return nil }
        let now = CFAbsoluteTimeGetCurrent()
        let selection = state.presentationController.nextFrame(
            frames: &state.pendingFrames,
            after: submittedCursor,
            policy: presentationLatencyPolicyLocked(state: state, now: now),
            now: now
        )
        recordPendingFrameTrimLocked(selection.trimResult, state: state)
        recordPendingQueueSampleLocked(state: state, now: now)
        state.lastSelectedFrameNumber = selection.selectedFrameNumber
        return selection.frame
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
        state.presentationController.resetPresentationEpoch(
            policy: presentationLatencyPolicyLocked(state: state),
            now: CFAbsoluteTimeGetCurrent()
        )
        state.lock.unlock()
        return count
    }

    /// Resets local playout state after presentation recovery while retaining stream identity.
    @discardableResult
    func resetPresentation(
        for streamID: StreamID,
        dropPendingFrames: Bool,
        reason: String
    ) -> Int {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        let now = CFAbsoluteTimeGetCurrent()
        state.lock.lock()
        let droppedFrameCount: Int
        if dropPendingFrames {
            droppedFrameCount = state.pendingFrames.count
            state.pendingFrames.removeAll(keepingCapacity: false)
        } else {
            droppedFrameCount = 0
        }
        state.presentationController.resetPresentationEpoch(
            policy: presentationLatencyPolicyLocked(state: state, now: now),
            now: now
        )
        if dropPendingFrames, droppedFrameCount > 0 {
            state.smoothestQueueDropsSinceLastSnapshot &+= UInt64(droppedFrameCount)
            state.smoothestDisplayDebtDropsSinceLastSnapshot &+= UInt64(droppedFrameCount)
            state.smoothestFifoResetCountSinceLastSnapshot &+= 1
        }
        recordPendingQueueSampleLocked(state: state, now: now)
        state.lock.unlock()

        MirageLogger.renderer(
            "Reset presentation playout for stream \(streamID) reason=\(reason) dropped=\(droppedFrameCount)"
        )
        return droppedFrameCount
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
            playoutDelayFrames: state.playoutDelayFrames,
            latencyMode: state.latencyMode
        )
        state.lock.unlock()
        return timing
    }

    func setCadenceTarget(for streamID: StreamID, target: MirageStreamCadenceTarget) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.sourceTargetFPS = target.sourceFPS
        state.displayTargetFPS = target.displayFPS
        let latencyModeChanged = state.latencyMode != target.latencyMode
        state.latencyMode = target.latencyMode
        state.playoutDelayFrames = target.playoutDelayFrames
        if latencyModeChanged {
            state.presentationController.reset()
        }
        trimPendingFramesToCurrentCapacityLocked(state: state)
        state.lock.unlock()
    }

    func setDisplayTargetFPS(for streamID: StreamID, displayFPS: Int) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.displayTargetFPS = MirageRenderModePolicy.normalizedTargetFPS(displayFPS)
        state.lock.unlock()
    }

    func noteInteraction(for streamID: StreamID, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.lastInteractionTime = now
        state.lock.unlock()
    }

    func setTransportPathKind(for streamID: StreamID, pathKind: MirageNetworkPathKind) {
        let state = streamState(for: streamID)
        state.lock.lock()
        if state.transportPathKind != pathKind {
            state.transportPathKind = pathKind
            state.presentationController.reset()
        }
        state.lock.unlock()
    }

    func setLatencyMode(
        for streamID: StreamID,
        latencyMode: MirageStreamLatencyMode,
        playoutDelayFrames: Int? = nil
    ) {
        let state = streamState(for: streamID)
        state.lock.lock()
        let latencyModeChanged = state.latencyMode != latencyMode
        state.latencyMode = latencyMode
        state.playoutDelayFrames = MirageStreamCadenceTarget.clampedPlayoutDelayFrames(
            playoutDelayFrames ?? presentationLatencyPolicyLocked(state: state).targetPlayoutDelayFrames
        )
        if latencyModeChanged {
            state.presentationController.reset()
        }
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
        let now = CFAbsoluteTimeGetCurrent()
        let result = state.presentationController.trimAfterPolicyChange(
            frames: &state.pendingFrames,
            policy: presentationLatencyPolicyLocked(state: state, now: now),
            now: now
        )
        recordPendingFrameTrimLocked(result, state: state)
    }

    private func resetPresentationEpochIfMetadataChangedLocked(
        state: MirageRenderStreamState,
        hostEpoch: UInt16?,
        dimensionToken: UInt16?,
        now: CFAbsoluteTime
    ) {
        let hostEpochChanged = if let hostEpoch,
                                  let previous = state.lastEnqueuedHostEpoch {
            hostEpoch != previous
        } else {
            false
        }
        let dimensionTokenChanged = if let dimensionToken,
                                       let previous = state.lastEnqueuedDimensionToken {
            dimensionToken != previous
        } else {
            false
        }

        if hostEpochChanged || dimensionTokenChanged {
            let droppedFrameCount = state.pendingFrames.count
            state.pendingFrames.removeAll(keepingCapacity: false)
            state.presentationController.resetPresentationEpoch(
                policy: presentationLatencyPolicyLocked(state: state, now: now),
                now: now
            )
            if droppedFrameCount > 0 {
                state.smoothestQueueDropsSinceLastSnapshot &+= UInt64(droppedFrameCount)
                state.smoothestDisplayDebtDropsSinceLastSnapshot &+= UInt64(droppedFrameCount)
                state.smoothestFifoResetCountSinceLastSnapshot &+= 1
            }
        }

        if let hostEpoch {
            state.lastEnqueuedHostEpoch = hostEpoch
        }
        if let dimensionToken {
            state.lastEnqueuedDimensionToken = dimensionToken
        }
    }

    private func recordPendingFrameTrimLocked(
        _ result: MirageVideoPlayoutBuffer.TrimResult,
        state: MirageRenderStreamState
    ) {
        recordOverwrittenPendingFramesLocked(result.overwrittenPendingFrames, state: state)
        recordSmoothestQueueDropsLocked(result.smoothestQueueDrops, state: state)
        recordSmoothestDepthDropsLocked(result.smoothestDepthDrops, state: state)
        recordSmoothestAgeDropsLocked(result.smoothestAgeDrops, state: state)
        recordSmoothestDropsUnder100msLocked(result.smoothestDropsUnder100ms, state: state)
        recordSmoothestDroppedFrameAgeMaxLocked(result.smoothestDroppedFrameAgeMaxMs, state: state)
        recordSmoothestDisplayDebtDropsLocked(result.smoothestDisplayDebtDrops, state: state)
        recordSmoothestFifoResetLocked(result.smoothestFifoResetCount, state: state)
        recordLateFrameDropsLocked(result.lateFrameDrops, state: state)
        recordCoalescedFramesLocked(result.coalescedFrames, state: state)
    }

    private func recordOverwrittenPendingFramesLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.overwrittenPendingFramesSinceLastSnapshot &+= UInt64(count)
    }

    private func recordSmoothestQueueDropsLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.smoothestQueueDropsSinceLastSnapshot &+= UInt64(count)
    }

    private func recordSmoothestDepthDropsLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.smoothestDepthDropsSinceLastSnapshot &+= UInt64(count)
    }

    private func recordSmoothestAgeDropsLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.smoothestAgeDropsSinceLastSnapshot &+= UInt64(count)
    }

    private func recordSmoothestDropsUnder100msLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.smoothestDropsUnder100msSinceLastSnapshot &+= UInt64(count)
    }

    private func recordSmoothestDroppedFrameAgeMaxLocked(_ ageMs: Double, state: MirageRenderStreamState) {
        guard ageMs.isFinite, ageMs > 0 else { return }
        state.smoothestDroppedFrameAgeMaxMsSinceLastSnapshot = max(
            state.smoothestDroppedFrameAgeMaxMsSinceLastSnapshot,
            ageMs
        )
    }

    private func recordSmoothestDisplayDebtDropsLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.smoothestDisplayDebtDropsSinceLastSnapshot &+= UInt64(count)
    }

    private func recordSmoothestFifoResetLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.smoothestFifoResetCountSinceLastSnapshot &+= UInt64(count)
    }

    private func recordLateFrameDropsLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.lateFrameDropsSinceLastSnapshot &+= UInt64(count)
    }

    private func recordCoalescedFramesLocked(_ count: Int, state: MirageRenderStreamState) {
        guard count > 0 else { return }
        state.coalescedFramesSinceLastSnapshot &+= UInt64(count)
    }

    func presentationLatencyPolicyLocked(
        state: MirageRenderStreamState,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> MiragePresentationLatencyPolicy {
        MiragePresentationLatencyPolicy(
            latencyMode: state.latencyMode,
            sourceFPS: state.sourceTargetFPS,
            displayFPS: state.displayTargetFPS,
            transportPathKind: state.transportPathKind,
            hasRecentInteraction: hasRecentInteractionLocked(state: state, now: now),
            lastInteractionAgeSeconds: lastInteractionAgeSecondsLocked(state: state, now: now)
        )
    }

    private func hasRecentInteractionLocked(
        state: MirageRenderStreamState,
        now: CFAbsoluteTime
    ) -> Bool {
        guard state.lastInteractionTime > 0 else { return false }
        return max(0, now - state.lastInteractionTime) < 1.500
    }

    private func lastInteractionAgeSecondsLocked(
        state: MirageRenderStreamState,
        now: CFAbsoluteTime
    ) -> CFTimeInterval? {
        guard state.lastInteractionTime > 0 else { return nil }
        return max(0, now - state.lastInteractionTime)
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
