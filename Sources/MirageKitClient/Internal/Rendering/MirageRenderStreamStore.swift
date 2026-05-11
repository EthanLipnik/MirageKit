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
        let cursor: MirageRenderCursor
        let didEnqueue: Bool
        let pendingFrameCount: Int
        let pendingFrameAgeMs: Double
        let overwrittenPendingFrames: Int
    }

    struct SubmissionSnapshot: Sendable {
        let cursor: MirageRenderCursor
        let submittedTime: CFAbsoluteTime
        let remotePresentationTime: CMTime
        let mappedPresentationTime: CMTime
        let visibleCursor: MirageRenderCursor
        let visibleSubmittedTime: CFAbsoluteTime

        var hasSubmission: Bool { cursor.hasSubmittedFrame && submittedTime > 0 }
        var hasVisibleFrame: Bool { visibleCursor.hasSubmittedFrame && visibleSubmittedTime > 0 }
    }

    struct PresentedFrameIdentity: Equatable, Sendable {
        let cursor: MirageRenderCursor
        let hostEpoch: UInt16?
        let dimensionToken: UInt16?
        let frameNumber: UInt32?
        let remotePresentationTimeValue: CMTimeValue?
        let remotePresentationTimeScale: CMTimeScale?

        init(
            cursor: MirageRenderCursor,
            hostEpoch: UInt16? = nil,
            dimensionToken: UInt16? = nil,
            frameNumber: UInt32? = nil,
            remotePresentationTime: CMTime = .invalid
        ) {
            self.cursor = cursor
            self.hostEpoch = hostEpoch
            self.dimensionToken = dimensionToken
            self.frameNumber = frameNumber
            if remotePresentationTime.isValid {
                remotePresentationTimeValue = remotePresentationTime.value
                remotePresentationTimeScale = remotePresentationTime.timescale
            } else {
                remotePresentationTimeValue = nil
                remotePresentationTimeScale = nil
            }
        }

        init(frame: MirageRenderFrame) {
            self.init(
                cursor: frame.cursor,
                hostEpoch: frame.hostEpoch,
                dimensionToken: frame.dimensionToken,
                frameNumber: frame.frameNumber,
                remotePresentationTime: frame.remotePresentationTime.isValid
                    ? frame.remotePresentationTime
                    : frame.presentationTime
            )
        }

        func representsSameSourceFrame(as other: PresentedFrameIdentity) -> Bool {
            if let frameNumber,
               let otherFrameNumber = other.frameNumber,
               frameNumber == otherFrameNumber,
               hostEpoch == other.hostEpoch,
               dimensionToken == other.dimensionToken {
                return true
            }
            if let remotePresentationTimeValue,
               let remotePresentationTimeScale,
               let otherRemotePresentationTimeValue = other.remotePresentationTimeValue,
               let otherRemotePresentationTimeScale = other.remotePresentationTimeScale,
               remotePresentationTimeValue == otherRemotePresentationTimeValue,
               remotePresentationTimeScale == otherRemotePresentationTimeScale,
               hostEpoch == other.hostEpoch,
               dimensionToken == other.dimensionToken {
                return true
            }
            return cursor == other.cursor
        }
    }

    struct DiagnosticsSnapshot: Sendable {
        let generation: UInt64
        let clearCount: UInt64
        let generationBumpCount: UInt64
        let memoryTrimClearCount: UInt64
        let presenterTimingResetCount: UInt64
        let presenterTimingResetReasons: String?
        let displayLayerLivenessResetCount: UInt64
        let displayLayerLivenessResetReasons: String?
        let presentationRecoveryRequestCount: UInt64
        let presentationRecoveryHandlerDispatchCount: UInt64
        let lastGenerationBumpReason: String?
        let lastPresentationRecoveryOutcome: String?
    }

    struct RenderTelemetrySnapshot: Sendable {
        let decodeFPS: Double
        let renderStoreEnqueueFPS: Double
        let displayLinkCallbackFPS: Double
        let displayTickWorkerFPS: Double
        let displayTickMainRelayFPS: Double
        let displayTickFPS: Double
        let presentationPassFPS: Double
        let presentationEligibleFPS: Double
        let submitAttemptFPS: Double
        let layerEnqueueFPS: Double
        let uniqueLayerEnqueueFPS: Double
        let visibleFrameFPS: Double
        let visibleFrameCadenceKnown: Bool
        let visiblePresentationStallCount: UInt64
        let visibleWorstPresentationGapMs: Double
        let visibleFrameIntervalP95Ms: Double
        let visibleFrameIntervalP99Ms: Double
        let visibleFrameIntervalMaxMs: Double
        let repeatedSourceFrameCount: UInt64
        let framesSubmittedPerPassAverage: Double
        let framesSubmittedPerPassMax: UInt64
        let pendingFrameCount: Int
        let unsubmittedPendingFrameCount: Int
        let retainedSubmittedFrameCount: Int
        let pendingFrameAgeMs: Double
        let oldestUnsubmittedAgeMs: Double
        let newestUnsubmittedAgeMs: Double
        let overwrittenPendingFrames: UInt64
        let renderStoreOverwriteFPS: Double
        let lowestLatencyFreshBacklogDrops: UInt64
        let lateFrameDrops: UInt64
        let coalescedBeforeSubmitCount: UInt64
        let duplicateRemoteTimestampCount: UInt64
        let correctedStreamTimestampCount: UInt64
        let displayLayerNotReadyCount: UInt64
        let sampleBufferRendererNotReadyCount: UInt64
        let displayImmediatelySubmittedCount: UInt64
        let rendererReadyDrainPassCount: UInt64
        let rendererReadyDrainSubmittedCount: UInt64
        let rendererReadyRearmCount: UInt64
        let repeatedFrameCount: UInt64
        let displayTickNoFrameCount: UInt64
        let tickNoEligibleFrameCount: UInt64
        let frameArrivedAfterNoFrameTickCount: UInt64
        let frameArrivalFallbackCount: UInt64
        let frameArrivalFallbackScheduledCount: UInt64
        let frameArrivalFallbackSubmittedCount: UInt64
        let noFrameTickToFrameArrivalMaxMs: Double
        let missedVSyncCount: UInt64
        let smoothestOneFrameHoldCount: UInt64
        let displayCadenceBelowSourceCount: UInt64
        let displayTickIntervalP95Ms: Double
        let displayTickIntervalP99Ms: Double
        let playoutDelayFrames: Int
        let presentationStallCount: UInt64
        let worstPresentationGapMs: Double
        let frameIntervalP95Ms: Double
        let frameIntervalP99Ms: Double
        let frameIntervalMaxMs: Double
        let displayTickIntervalMaxMs: Double
        let displayTickMainDelayMaxMs: Double
        let renderWorkerSubmitDelayMaxMs: Double
        let decodeHealthy: Bool
        let severeDecodeUnderrun: Bool
        let sourceTargetFPS: Int
        let displayTargetFPS: Int
        let targetFPS: Int

        var rendererEnqueueFPS: Double { layerEnqueueFPS }
        var uniqueRendererEnqueueFPS: Double { uniqueLayerEnqueueFPS }
        var uniqueDeliveredSourceFrameFPS: Double { visibleFrameFPS }
        var deliveredSourceFrameCadenceKnown: Bool { visibleFrameCadenceKnown }
        var repeatedDeliveredSourceFrameCount: UInt64 { repeatedSourceFrameCount }
        var repeatedDisplayTickFrameCount: UInt64 { repeatedFrameCount }
        var displayRefreshTickFPS: Double { displayTickFPS }
        var renderQueueBacklogFrames: Int { unsubmittedPendingFrameCount }
    }

    struct FeedbackTelemetrySnapshot: Sendable, Equatable {
        let pendingFrameCount: Int
        let layerEnqueueFPS: Double
        let uniqueLayerEnqueueFPS: Double
        let visibleFrameFPS: Double
        let visibleFrameCadenceKnown: Bool

        var rendererEnqueueFPS: Double { layerEnqueueFPS }
        var uniqueRendererEnqueueFPS: Double { uniqueLayerEnqueueFPS }
        var uniqueDeliveredSourceFrameFPS: Double { visibleFrameFPS }
        var deliveredSourceFrameCadenceKnown: Bool { visibleFrameCadenceKnown }
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
        var generation: UInt64
        var pendingFrames: [MirageRenderFrame] = []
        var nextSequence: UInt64 = 0
        var lastSubmittedSequence: UInt64 = 0
        var lastSubmittedTime: CFAbsoluteTime = 0
        var lastSubmittedRemotePresentationTime: CMTime = .invalid
        var lastSubmittedMappedPresentationTime: CMTime = .invalid
        var lastAcceptedFrameTimeline: FrameTimeline?
        var lastDisplayTickTime: CFAbsoluteTime = 0
        var sourceTargetFPS: Int = 60
        var displayTargetFPS: Int = 60
        var latencyMode: MirageStreamLatencyMode = .lowestLatency
        var playoutDelayFrames: Int = 0
        var listeners: [ObjectIdentifier: FrameListener] = [:]
        var presentationRecoveryHandlers: [ObjectIdentifier: FrameListener] = [:]

        var decodeSamples: [CFAbsoluteTime] = []
        var decodeSampleStartIndex: Int = 0
        var displayLinkCallbackSamples: [CFAbsoluteTime] = []
        var displayLinkCallbackSampleStartIndex: Int = 0
        var displayTickWorkerSamples: [CFAbsoluteTime] = []
        var displayTickWorkerSampleStartIndex: Int = 0
        var displayTickMainRelaySamples: [CFAbsoluteTime] = []
        var displayTickMainRelaySampleStartIndex: Int = 0
        var displayTickSamples: [CFAbsoluteTime] = []
        var displayTickSampleStartIndex: Int = 0
        var presentationPassSamples: [CFAbsoluteTime] = []
        var presentationPassSampleStartIndex: Int = 0
        var presentationEligibleSamples: [CFAbsoluteTime] = []
        var presentationEligibleSampleStartIndex: Int = 0
        var submitAttemptSamples: [CFAbsoluteTime] = []
        var submitAttemptSampleStartIndex: Int = 0
        var renderStoreOverwriteSamples: [CFAbsoluteTime] = []
        var renderStoreOverwriteSampleStartIndex: Int = 0
        var submittedSamples: [CFAbsoluteTime] = []
        var submittedSampleStartIndex: Int = 0
        var uniqueSubmittedSamples: [CFAbsoluteTime] = []
        var uniqueSubmittedSampleStartIndex: Int = 0
        var visibleFrameSamples: [CFAbsoluteTime] = []
        var visibleFrameSampleStartIndex: Int = 0
        var frameIntervalSamples: [(time: CFAbsoluteTime, intervalMs: Double)] = []
        var frameIntervalSampleStartIndex: Int = 0
        var visibleFrameIntervalSamples: [(time: CFAbsoluteTime, intervalMs: Double)] = []
        var visibleFrameIntervalSampleStartIndex: Int = 0
        var displayTickIntervalSamples: [(time: CFAbsoluteTime, intervalMs: Double)] = []
        var displayTickIntervalSampleStartIndex: Int = 0

        var overwrittenPendingFramesSinceLastSnapshot: UInt64 = 0
        var lowestLatencyFreshBacklogDropsSinceLastSnapshot: UInt64 = 0
        var lateFrameDropsSinceLastSnapshot: UInt64 = 0
        var coalescedFramesSinceLastSnapshot: UInt64 = 0
        var framesSubmittedPerPassTotalSinceLastSnapshot: UInt64 = 0
        var presentationPassCountSinceLastSnapshot: UInt64 = 0
        var framesSubmittedPerPassMaxSinceLastSnapshot: UInt64 = 0
        var duplicateRemoteTimestampsSinceLastSnapshot: UInt64 = 0
        var correctedStreamTimestampsSinceLastSnapshot: UInt64 = 0
        var displayLayerNotReadyCountSinceLastSnapshot: UInt64 = 0
        var sampleBufferRendererNotReadyCountSinceLastSnapshot: UInt64 = 0
        var displayImmediatelySubmittedCountSinceLastSnapshot: UInt64 = 0
        var rendererReadyDrainPassCountSinceLastSnapshot: UInt64 = 0
        var rendererReadyDrainSubmittedCountSinceLastSnapshot: UInt64 = 0
        var rendererReadyRearmCountSinceLastSnapshot: UInt64 = 0
        var repeatedFrameCountSinceLastSnapshot: UInt64 = 0
        var displayTickNoFrameCountSinceLastSnapshot: UInt64 = 0
        var frameArrivedAfterNoFrameTickCountSinceLastSnapshot: UInt64 = 0
        var frameArrivalFallbackCountSinceLastSnapshot: UInt64 = 0
        var frameArrivalFallbackSubmittedCountSinceLastSnapshot: UInt64 = 0
        var noFrameTickToFrameArrivalMaxMsSinceLastSnapshot: Double = 0
        var missedVSyncCountSinceLastSnapshot: UInt64 = 0
        var smoothestOneFrameHoldCountSinceLastSnapshot: UInt64 = 0
        var displayCadenceBelowSourceCountSinceLastSnapshot: UInt64 = 0
        var displayTickMainDelayMaxMsSinceLastSnapshot: Double = 0
        var renderWorkerSubmitDelayMaxMsSinceLastSnapshot: Double = 0
        var presentationStallCountSinceLastSnapshot: UInt64 = 0
        var worstPresentationGapMsSinceLastSnapshot: Double = 0
        var visiblePresentationStallCountSinceLastSnapshot: UInt64 = 0
        var visibleWorstPresentationGapMsSinceLastSnapshot: Double = 0
        var repeatedSourceFrameCountSinceLastSnapshot: UInt64 = 0
        var clearCount: UInt64 = 0
        var generationBumpCount: UInt64 = 0
        var memoryTrimClearCount: UInt64 = 0
        var presenterTimingResetCount: UInt64 = 0
        var presenterTimingResetReasonCounts: [String: UInt64] = [:]
        var displayLayerLivenessResetCount: UInt64 = 0
        var displayLayerLivenessResetReasonCounts: [String: UInt64] = [:]
        var presentationRecoveryRequestCount: UInt64 = 0
        var presentationRecoveryHandlerDispatchCount: UInt64 = 0
        var lastGenerationBumpReason: String?
        var lastPresentationRecoveryOutcome: String?
        var lastPresentedFrameIdentity: PresentedFrameIdentity?
        var lastVisibleFrameTime: CFAbsoluteTime = 0

        init(generation: UInt64) {
            self.generation = generation
        }
    }

    private let stateLock = NSLock()
    private var streams: [StreamID: StreamState] = [:]
    private var generationByStreamID: [StreamID: UInt64] = [:]
    private let sampleWindowSeconds: CFAbsoluteTime = 1.0
    private let smoothnessWindowSeconds: CFAbsoluteTime = 30.0
    private let presentationStallThresholdMs: Double = 500
    private let lowestLatencyMaximumPendingFrames: Int = 1
    private let smoothestFreshBurstWindowSeconds: CFAbsoluteTime = 0.10
    private let smoothestFreshBurstMaximumFrames: Int = 8
    private let initialGeneration: UInt64 = 1

    private init() {}

    @discardableResult
    func enqueue(
        pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        presentationTime: CMTime,
        remotePresentationTime: CMTime = .invalid,
        generation capturedGeneration: UInt64? = nil,
        hostEpoch: UInt16? = nil,
        dimensionToken: UInt16? = nil,
        frameNumber: UInt32? = nil,
        queueEpoch: UInt64? = nil,
        timeline: FrameTimeline? = nil,
        for streamID: StreamID
    ) -> EnqueueResult {
        let state = streamState(for: streamID)
        var listeners: [@Sendable () -> Void] = []
        let result: EnqueueResult

        state.lock.lock()
        let generation = capturedGeneration ?? state.generation
        guard generation == state.generation else {
            result = EnqueueResult(
                cursor: MirageRenderCursor(generation: generation, sequence: 0),
                didEnqueue: false,
                pendingFrameCount: state.pendingFrames.count,
                pendingFrameAgeMs: pendingFrameAgeMsLocked(state: state, now: CFAbsoluteTimeGetCurrent()),
                overwrittenPendingFrames: 0
            )
            state.lock.unlock()
            return result
        }

        state.nextSequence &+= 1
        let cursor = MirageRenderCursor(generation: state.generation, sequence: state.nextSequence)
        let now = CFAbsoluteTimeGetCurrent()
        let renderTimeline = timeline?.markingRenderEnqueued(
            at: decodeTime,
            queueAgeMs: max(0, now - decodeTime) * 1000
        )
        let frame = MirageRenderFrame(
            pixelBuffer: pixelBuffer,
            contentRect: contentRect,
            presentationMetadata: MirageRenderFramePresentationMetadata(
                pixelBuffer: pixelBuffer,
                contentRect: contentRect
            ),
            cursor: cursor,
            decodeTime: decodeTime,
            presentationTime: presentationTime,
            remotePresentationTime: remotePresentationTime,
            hostEpoch: hostEpoch,
            dimensionToken: dimensionToken,
            frameNumber: frameNumber,
            queueEpoch: queueEpoch,
            timeline: renderTimeline
        )
        let overwrittenPendingFrames = appendPendingFrameLocked(frame, state: state)
        appendSampleLocked(now, samples: &state.decodeSamples, startIndex: &state.decodeSampleStartIndex)
        listeners = activeListenersLocked(state: state)
        result = EnqueueResult(
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

    func takePendingFrame(for streamID: StreamID) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        defer { state.lock.unlock() }

        guard !state.pendingFrames.isEmpty else { return nil }

        let droppedLateFrames = trimPendingFramesForSelectionLocked(state: state, now: CFAbsoluteTimeGetCurrent())
        if droppedLateFrames > 0 {
            state.lateFrameDropsSinceLastSnapshot &+= UInt64(droppedLateFrames)
            state.coalescedFramesSinceLastSnapshot &+= UInt64(droppedLateFrames)
        }

        return state.pendingFrames.removeFirst()
    }

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

        droppedLateFrames += trimPendingFramesForSelectionLocked(state: state, now: CFAbsoluteTimeGetCurrent())
        if droppedLateFrames > 0 {
            state.lateFrameDropsSinceLastSnapshot &+= UInt64(droppedLateFrames)
            state.coalescedFramesSinceLastSnapshot &+= UInt64(droppedLateFrames)
        }

        return state.pendingFrames.first
    }

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

    func hasFrameForPresentation(for streamID: StreamID, after submittedCursor: MirageRenderCursor) -> Bool {
        guard let state = streamStateIfPresent(for: streamID) else { return false }
        state.lock.lock()
        let hasFrame = state.pendingFrames.last?.cursor.isAfter(submittedCursor) ?? false
        state.lock.unlock()
        return hasFrame
    }

    func peekPendingFrame(for streamID: StreamID) -> MirageRenderFrame? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        let frame = state.pendingFrames.first
        state.lock.unlock()
        return frame
    }

    func pendingFrameCount(for streamID: StreamID) -> Int {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let count = state.pendingFrames.count
        state.lock.unlock()
        return count
    }

    func pendingFrameCount(for streamID: StreamID, after submittedCursor: MirageRenderCursor) -> Int {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        guard state.pendingFrames.last?.cursor.isAfter(submittedCursor) == true else {
            state.lock.unlock()
            return 0
        }
        let count = state.pendingFrames.reduce(into: 0) { result, frame in
            if frame.cursor.isAfter(submittedCursor) {
                result += 1
            }
        }
        state.lock.unlock()
        return count
    }

    func shouldPreserveSmoothestPacingFrame(
        for streamID: StreamID,
        after submittedCursor: MirageRenderCursor
    ) -> Bool {
        guard let state = streamStateIfPresent(for: streamID) else { return false }
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        defer { state.lock.unlock() }

        guard state.latencyMode == .smoothest else { return false }
        while let first = state.pendingFrames.first, !first.cursor.isAfter(submittedCursor) {
            state.pendingFrames.removeFirst()
        }
        guard state.pendingFrames.count == 1,
              let pendingFrame = state.pendingFrames.first,
              pendingFrame.cursor.isAfter(submittedCursor)
        else {
            return false
        }

        let freshnessWindow = freshInOrderBurstWindowLocked(state: state, now: now)
        guard now - pendingFrame.decodeTime <= freshnessWindow else { return false }

        if displayCadenceBelowSourceLocked(state: state) {
            state.displayCadenceBelowSourceCountSinceLastSnapshot &+= 1
            return false
        }

        state.smoothestOneFrameHoldCountSinceLastSnapshot &+= 1
        return true
    }

    func allowsMultipleFramePresentationPass(for streamID: StreamID) -> Bool {
        guard let state = streamStateIfPresent(for: streamID) else { return false }
        state.lock.lock()
        let allowsMultipleFrames = state.latencyMode != .lowestLatency
        state.lock.unlock()
        return allowsMultipleFrames
    }

    func shouldDisplayFrameImmediately(
        for streamID: StreamID,
        cursor: MirageRenderCursor
    ) -> Bool {
        guard let state = streamStateIfPresent(for: streamID) else { return false }

        state.lock.lock()
        defer { state.lock.unlock() }

        switch state.latencyMode {
        case .lowestLatency:
            return true
        case .smoothest:
            if displayCadenceBelowSourceLocked(state: state) {
                state.displayCadenceBelowSourceCountSinceLastSnapshot &+= 1
                return true
            }
            let pendingAfterFrame = state.pendingFrames.reduce(into: 0) { result, frame in
                if frame.cursor.isAfter(cursor) {
                    result += 1
                }
            }
            return pendingAfterFrame > effectivePlayoutDelayFramesLocked(state: state)
        }
    }

    func pendingFrameAgeMs(for streamID: StreamID, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Double {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let age = pendingFrameAgeMsLocked(state: state, now: now)
        state.lock.unlock()
        return age
    }

    @discardableResult
    func clearPendingFrames(for streamID: StreamID) -> Int {
        guard let state = streamStateIfPresent(for: streamID) else { return 0 }
        state.lock.lock()
        let count = state.pendingFrames.count
        state.pendingFrames.removeAll(keepingCapacity: false)
        state.memoryTrimClearCount &+= 1
        state.lock.unlock()
        return count
    }

    func latestCursor(for streamID: StreamID) -> MirageRenderCursor {
        guard let state = streamStateIfPresent(for: streamID) else {
            return MirageRenderCursor(generation: currentGeneration(for: streamID), sequence: 0)
        }
        state.lock.lock()
        let cursor = MirageRenderCursor(generation: state.generation, sequence: state.nextSequence)
        state.lock.unlock()
        return cursor
    }

    func currentGeneration(for streamID: StreamID) -> UInt64 {
        stateLock.lock()
        let state = streams[streamID]
        let storedGeneration = generationByStreamID[streamID] ?? initialGeneration
        stateLock.unlock()

        guard let state else { return storedGeneration }
        state.lock.lock()
        let generation = state.generation
        state.lock.unlock()
        return generation
    }

    func baselineCursor(for streamID: StreamID) -> MirageRenderCursor {
        MirageRenderCursor(generation: currentGeneration(for: streamID), sequence: 0)
    }

    func notePresentationPass(for streamID: StreamID, framesSubmitted: Int) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()
        let submittedCount = UInt64(max(0, framesSubmitted))

        state.lock.lock()
        appendSampleLocked(
            now,
            samples: &state.presentationPassSamples,
            startIndex: &state.presentationPassSampleStartIndex
        )
        state.presentationPassCountSinceLastSnapshot &+= 1
        state.framesSubmittedPerPassTotalSinceLastSnapshot &+= submittedCount
        state.framesSubmittedPerPassMaxSinceLastSnapshot = max(
            state.framesSubmittedPerPassMaxSinceLastSnapshot,
            submittedCount
        )
        state.lock.unlock()
    }

    func noteDisplayTick(for streamID: StreamID) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        appendSampleLocked(now, samples: &state.displayTickSamples, startIndex: &state.displayTickSampleStartIndex)
        if state.lastDisplayTickTime > 0 {
            let intervalMs = max(0, now - state.lastDisplayTickTime) * 1000
            appendFrameIntervalSampleLocked(
                time: now,
                intervalMs: intervalMs,
                samples: &state.displayTickIntervalSamples,
                startIndex: &state.displayTickIntervalSampleStartIndex
            )
            let targetFrameMs = 1000 / Double(max(1, state.displayTargetFPS))
            if intervalMs > targetFrameMs * 1.5 {
                state.missedVSyncCountSinceLastSnapshot &+= 1
            }
        }
        state.lastDisplayTickTime = now
        state.lock.unlock()
    }

    func noteDisplayLinkCallbacks(for streamID: StreamID, count: UInt64 = 1) {
        guard count > 0 else { return }
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        for _ in 0 ..< count {
            appendSampleLocked(
                now,
                samples: &state.displayLinkCallbackSamples,
                startIndex: &state.displayLinkCallbackSampleStartIndex
            )
        }
        state.lock.unlock()
    }

    func noteDisplayTickWorker(for streamID: StreamID) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        appendSampleLocked(
            now,
            samples: &state.displayTickWorkerSamples,
            startIndex: &state.displayTickWorkerSampleStartIndex
        )
        state.lock.unlock()
    }

    func noteDisplayTickMainRelay(for streamID: StreamID, delayMs: Double) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        appendSampleLocked(
            now,
            samples: &state.displayTickMainRelaySamples,
            startIndex: &state.displayTickMainRelaySampleStartIndex
        )
        state.displayTickMainDelayMaxMsSinceLastSnapshot = max(
            state.displayTickMainDelayMaxMsSinceLastSnapshot,
            max(0, delayMs)
        )
        state.lock.unlock()
    }

    func noteRenderWorkerSubmitDelay(for streamID: StreamID, delayMs: Double) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.renderWorkerSubmitDelayMaxMsSinceLastSnapshot = max(
            state.renderWorkerSubmitDelayMaxMsSinceLastSnapshot,
            max(0, delayMs)
        )
        state.lock.unlock()
    }

    func noteRepeatedDisplayTick(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        if state.lastSubmittedSequence > 0 {
            state.repeatedFrameCountSinceLastSnapshot &+= 1
        }
        state.lock.unlock()
    }

    func noteDisplayTickWithoutFrame(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.displayTickNoFrameCountSinceLastSnapshot &+= 1
        state.lock.unlock()
    }

    func noteFrameArrivedAfterNoFrameTick(for streamID: StreamID, delayMs: Double) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.frameArrivedAfterNoFrameTickCountSinceLastSnapshot &+= 1
        state.noFrameTickToFrameArrivalMaxMsSinceLastSnapshot = max(
            state.noFrameTickToFrameArrivalMaxMsSinceLastSnapshot,
            max(0, delayMs)
        )
        state.lock.unlock()
    }

    func noteFrameArrivalFallback(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.frameArrivalFallbackCountSinceLastSnapshot &+= 1
        state.lock.unlock()
    }

    func noteFrameArrivalFallbackSubmitted(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.frameArrivalFallbackSubmittedCountSinceLastSnapshot &+= 1
        state.lock.unlock()
    }

    func markSubmitted(
        cursor: MirageRenderCursor,
        remotePresentationTime: CMTime = .invalid,
        mappedPresentationTime: CMTime,
        presentedFrameIdentity: PresentedFrameIdentity? = nil,
        for streamID: StreamID
    ) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        guard cursor.generation == state.generation else {
            state.lock.unlock()
            return
        }
        appendSampleLocked(now, samples: &state.submittedSamples, startIndex: &state.submittedSampleStartIndex)
        guard cursor.sequence > state.lastSubmittedSequence else {
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

        state.lastSubmittedSequence = cursor.sequence
        state.lastSubmittedTime = now
        state.lastSubmittedRemotePresentationTime = remotePresentationTime
        state.lastSubmittedMappedPresentationTime = mappedPresentationTime
        if let frameIndex = state.pendingFrames.firstIndex(where: { $0.cursor == cursor }) {
            let acceptedTimeline = state.pendingFrames[frameIndex].timeline?.markingDisplayAccepted(at: now)
            state.pendingFrames[frameIndex].timeline = acceptedTimeline
            state.lastAcceptedFrameTimeline = acceptedTimeline
        }
        appendSampleLocked(
            now,
            samples: &state.uniqueSubmittedSamples,
            startIndex: &state.uniqueSubmittedSampleStartIndex
        )
        let identity = presentedFrameIdentity ?? PresentedFrameIdentity(
            cursor: cursor,
            remotePresentationTime: remotePresentationTime
        )
        if let lastIdentity = state.lastPresentedFrameIdentity,
           identity.representsSameSourceFrame(as: lastIdentity) {
            state.repeatedSourceFrameCountSinceLastSnapshot &+= 1
        } else {
            if state.lastVisibleFrameTime > 0 {
                let intervalMs = max(0, now - state.lastVisibleFrameTime) * 1000
                appendFrameIntervalSampleLocked(
                    time: now,
                    intervalMs: intervalMs,
                    samples: &state.visibleFrameIntervalSamples,
                    startIndex: &state.visibleFrameIntervalSampleStartIndex
                )
                if intervalMs >= presentationStallThresholdMs {
                    state.visiblePresentationStallCountSinceLastSnapshot &+= 1
                    state.visibleWorstPresentationGapMsSinceLastSnapshot = max(
                        state.visibleWorstPresentationGapMsSinceLastSnapshot,
                        intervalMs
                    )
                }
            }
            state.lastVisibleFrameTime = now
            state.lastPresentedFrameIdentity = identity
            appendSampleLocked(
                now,
                samples: &state.visibleFrameSamples,
                startIndex: &state.visibleFrameSampleStartIndex
            )
        }
        state.lock.unlock()
    }

    func latestAcceptedFrameTimeline(for streamID: StreamID) -> FrameTimeline? {
        guard let state = streamStateIfPresent(for: streamID) else { return nil }
        state.lock.lock()
        let timeline = state.lastAcceptedFrameTimeline
        state.lock.unlock()
        return timeline
    }

    func submissionSnapshot(for streamID: StreamID) -> SubmissionSnapshot {
        guard let state = streamStateIfPresent(for: streamID) else {
            return SubmissionSnapshot(
                cursor: MirageRenderCursor(generation: currentGeneration(for: streamID), sequence: 0),
                submittedTime: 0,
                remotePresentationTime: .invalid,
                mappedPresentationTime: .invalid,
                visibleCursor: MirageRenderCursor(generation: currentGeneration(for: streamID), sequence: 0),
                visibleSubmittedTime: 0
            )
        }

        state.lock.lock()
        let visibleCursor = state.lastPresentedFrameIdentity?.cursor ??
            MirageRenderCursor(generation: state.generation, sequence: 0)
        let snapshot = SubmissionSnapshot(
            cursor: MirageRenderCursor(generation: state.generation, sequence: state.lastSubmittedSequence),
            submittedTime: state.lastSubmittedTime,
            remotePresentationTime: state.lastSubmittedRemotePresentationTime,
            mappedPresentationTime: state.lastSubmittedMappedPresentationTime,
            visibleCursor: visibleCursor,
            visibleSubmittedTime: state.lastVisibleFrameTime
        )
        state.lock.unlock()
        return snapshot
    }

    func diagnosticsSnapshot(for streamID: StreamID) -> DiagnosticsSnapshot {
        guard let state = streamStateIfPresent(for: streamID) else {
            return DiagnosticsSnapshot(
                generation: currentGeneration(for: streamID),
                clearCount: 0,
                generationBumpCount: 0,
                memoryTrimClearCount: 0,
                presenterTimingResetCount: 0,
                presenterTimingResetReasons: nil,
                displayLayerLivenessResetCount: 0,
                displayLayerLivenessResetReasons: nil,
                presentationRecoveryRequestCount: 0,
                presentationRecoveryHandlerDispatchCount: 0,
                lastGenerationBumpReason: nil,
                lastPresentationRecoveryOutcome: nil
            )
        }

        state.lock.lock()
        let snapshot = DiagnosticsSnapshot(
            generation: state.generation,
            clearCount: state.clearCount,
            generationBumpCount: state.generationBumpCount,
            memoryTrimClearCount: state.memoryTrimClearCount,
            presenterTimingResetCount: state.presenterTimingResetCount,
            presenterTimingResetReasons: Self.reasonSummary(state.presenterTimingResetReasonCounts),
            displayLayerLivenessResetCount: state.displayLayerLivenessResetCount,
            displayLayerLivenessResetReasons: Self.reasonSummary(state.displayLayerLivenessResetReasonCounts),
            presentationRecoveryRequestCount: state.presentationRecoveryRequestCount,
            presentationRecoveryHandlerDispatchCount: state.presentationRecoveryHandlerDispatchCount,
            lastGenerationBumpReason: state.lastGenerationBumpReason,
            lastPresentationRecoveryOutcome: state.lastPresentationRecoveryOutcome
        )
        state.lock.unlock()
        return snapshot
    }

    func recordPresenterTimingReset(for streamID: StreamID, reason: String) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.presenterTimingResetCount &+= 1
        state.presenterTimingResetReasonCounts[reason, default: 0] &+= 1
        state.lock.unlock()
    }

    func recordDisplayLayerLivenessReset(for streamID: StreamID, reason: String) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.displayLayerLivenessResetCount &+= 1
        state.displayLayerLivenessResetReasonCounts[reason, default: 0] &+= 1
        state.lock.unlock()
    }

    func noteSubmitAttempt(for streamID: StreamID) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()
        state.lock.lock()
        appendSampleLocked(now, samples: &state.submitAttemptSamples, startIndex: &state.submitAttemptSampleStartIndex)
        state.lock.unlock()
    }

    func notePresentationEligibleFrame(for streamID: StreamID) {
        let state = streamState(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()
        state.lock.lock()
        appendSampleLocked(
            now,
            samples: &state.presentationEligibleSamples,
            startIndex: &state.presentationEligibleSampleStartIndex
        )
        state.lock.unlock()
    }

    func noteDisplayLayerNotReady(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.displayLayerNotReadyCountSinceLastSnapshot &+= 1
        state.lock.unlock()
    }

    func noteSampleBufferRendererNotReady(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.sampleBufferRendererNotReadyCountSinceLastSnapshot &+= 1
        state.lock.unlock()
    }

    func noteDisplayImmediateSubmission(for streamID: StreamID) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.displayImmediatelySubmittedCountSinceLastSnapshot &+= 1
        state.lock.unlock()
    }

    func noteRendererReadyDrainPass(for streamID: StreamID, submittedFrames: Int, rearmed: Bool) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.rendererReadyDrainPassCountSinceLastSnapshot &+= 1
        state.rendererReadyDrainSubmittedCountSinceLastSnapshot &+= UInt64(max(0, submittedFrames))
        if rearmed {
            state.rendererReadyRearmCountSinceLastSnapshot &+= 1
        }
        state.lock.unlock()
    }

    func renderTelemetrySnapshot(
        for streamID: StreamID,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> RenderTelemetrySnapshot {
        guard let state = streamStateIfPresent(for: streamID) else {
            return RenderTelemetrySnapshot(
                decodeFPS: 0,
                renderStoreEnqueueFPS: 0,
                displayLinkCallbackFPS: 0,
                displayTickWorkerFPS: 0,
                displayTickMainRelayFPS: 0,
                displayTickFPS: 0,
                presentationPassFPS: 0,
                presentationEligibleFPS: 0,
                submitAttemptFPS: 0,
                layerEnqueueFPS: 0,
                uniqueLayerEnqueueFPS: 0,
                visibleFrameFPS: 0,
                visibleFrameCadenceKnown: false,
                visiblePresentationStallCount: 0,
                visibleWorstPresentationGapMs: 0,
                visibleFrameIntervalP95Ms: 0,
                visibleFrameIntervalP99Ms: 0,
                visibleFrameIntervalMaxMs: 0,
                repeatedSourceFrameCount: 0,
                framesSubmittedPerPassAverage: 0,
                framesSubmittedPerPassMax: 0,
                pendingFrameCount: 0,
                unsubmittedPendingFrameCount: 0,
                retainedSubmittedFrameCount: 0,
                pendingFrameAgeMs: 0,
                oldestUnsubmittedAgeMs: 0,
                newestUnsubmittedAgeMs: 0,
                overwrittenPendingFrames: 0,
                renderStoreOverwriteFPS: 0,
                lowestLatencyFreshBacklogDrops: 0,
                lateFrameDrops: 0,
                coalescedBeforeSubmitCount: 0,
                duplicateRemoteTimestampCount: 0,
                correctedStreamTimestampCount: 0,
                displayLayerNotReadyCount: 0,
                sampleBufferRendererNotReadyCount: 0,
                displayImmediatelySubmittedCount: 0,
                rendererReadyDrainPassCount: 0,
                rendererReadyDrainSubmittedCount: 0,
                rendererReadyRearmCount: 0,
                repeatedFrameCount: 0,
                displayTickNoFrameCount: 0,
                tickNoEligibleFrameCount: 0,
                frameArrivedAfterNoFrameTickCount: 0,
                frameArrivalFallbackCount: 0,
                frameArrivalFallbackScheduledCount: 0,
                frameArrivalFallbackSubmittedCount: 0,
                noFrameTickToFrameArrivalMaxMs: 0,
                missedVSyncCount: 0,
                smoothestOneFrameHoldCount: 0,
                displayCadenceBelowSourceCount: 0,
                displayTickIntervalP95Ms: 0,
                displayTickIntervalP99Ms: 0,
                playoutDelayFrames: 0,
                presentationStallCount: 0,
                worstPresentationGapMs: 0,
                frameIntervalP95Ms: 0,
                frameIntervalP99Ms: 0,
                frameIntervalMaxMs: 0,
                displayTickIntervalMaxMs: 0,
                displayTickMainDelayMaxMs: 0,
                renderWorkerSubmitDelayMaxMs: 0,
                decodeHealthy: true,
                severeDecodeUnderrun: false,
                sourceTargetFPS: 60,
                displayTargetFPS: 60,
                targetFPS: 60
            )
        }

        state.lock.lock()
        trimSamplesLocked(now: now, samples: &state.decodeSamples, startIndex: &state.decodeSampleStartIndex)
        trimSamplesLocked(
            now: now,
            samples: &state.displayLinkCallbackSamples,
            startIndex: &state.displayLinkCallbackSampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.displayTickWorkerSamples,
            startIndex: &state.displayTickWorkerSampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.displayTickMainRelaySamples,
            startIndex: &state.displayTickMainRelaySampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.displayTickSamples,
            startIndex: &state.displayTickSampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.presentationPassSamples,
            startIndex: &state.presentationPassSampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.presentationEligibleSamples,
            startIndex: &state.presentationEligibleSampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.submitAttemptSamples,
            startIndex: &state.submitAttemptSampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.renderStoreOverwriteSamples,
            startIndex: &state.renderStoreOverwriteSampleStartIndex
        )
        trimSamplesLocked(now: now, samples: &state.submittedSamples, startIndex: &state.submittedSampleStartIndex)
        trimSamplesLocked(
            now: now,
            samples: &state.uniqueSubmittedSamples,
            startIndex: &state.uniqueSubmittedSampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.visibleFrameSamples,
            startIndex: &state.visibleFrameSampleStartIndex
        )
        trimFrameIntervalSamplesLocked(
            now: now,
            samples: &state.frameIntervalSamples,
            startIndex: &state.frameIntervalSampleStartIndex
        )
        trimFrameIntervalSamplesLocked(
            now: now,
            samples: &state.visibleFrameIntervalSamples,
            startIndex: &state.visibleFrameIntervalSampleStartIndex
        )
        trimFrameIntervalSamplesLocked(
            now: now,
            samples: &state.displayTickIntervalSamples,
            startIndex: &state.displayTickIntervalSampleStartIndex
        )

        let decodeFPS = Double(state.decodeSamples.count - state.decodeSampleStartIndex)
        let displayLinkCallbackFPS = Double(
            state.displayLinkCallbackSamples.count - state.displayLinkCallbackSampleStartIndex
        )
        let displayTickWorkerFPS = Double(
            state.displayTickWorkerSamples.count - state.displayTickWorkerSampleStartIndex
        )
        let displayTickMainRelayFPS = Double(
            state.displayTickMainRelaySamples.count - state.displayTickMainRelaySampleStartIndex
        )
        let displayTickFPS = Double(state.displayTickSamples.count - state.displayTickSampleStartIndex)
        let presentationPassFPS = Double(
            state.presentationPassSamples.count - state.presentationPassSampleStartIndex
        )
        let presentationEligibleFPS = Double(
            state.presentationEligibleSamples.count - state.presentationEligibleSampleStartIndex
        )
        let submitAttemptFPS = Double(state.submitAttemptSamples.count - state.submitAttemptSampleStartIndex)
        let renderStoreOverwriteFPS = Double(
            state.renderStoreOverwriteSamples.count - state.renderStoreOverwriteSampleStartIndex
        )
        let layerEnqueueFPS = Double(state.submittedSamples.count - state.submittedSampleStartIndex)
        let uniqueLayerEnqueueFPS = Double(state.uniqueSubmittedSamples.count - state.uniqueSubmittedSampleStartIndex)
        let visibleFrameFPS = Double(state.visibleFrameSamples.count - state.visibleFrameSampleStartIndex)
        let visibleFrameCadenceKnown = state.lastVisibleFrameTime > 0
        let presentationPassCount = state.presentationPassCountSinceLastSnapshot
        let framesSubmittedPerPassAverage: Double
        if presentationPassCount > 0 {
            framesSubmittedPerPassAverage =
                Double(state.framesSubmittedPerPassTotalSinceLastSnapshot) / Double(presentationPassCount)
        } else {
            framesSubmittedPerPassAverage = 0
        }
        let framesSubmittedPerPassMax = state.framesSubmittedPerPassMaxSinceLastSnapshot
        let pendingFrameCount = state.pendingFrames.count
        let lastSubmittedCursor = MirageRenderCursor(
            generation: state.generation,
            sequence: state.lastSubmittedSequence
        )
        var oldestUnsubmittedDecodeTime: CFAbsoluteTime?
        var newestUnsubmittedDecodeTime: CFAbsoluteTime?
        let unsubmittedPendingFrameCount = state.pendingFrames.reduce(into: 0) { result, frame in
            if frame.cursor.isAfter(lastSubmittedCursor) {
                result += 1
                if oldestUnsubmittedDecodeTime == nil {
                    oldestUnsubmittedDecodeTime = frame.decodeTime
                }
                newestUnsubmittedDecodeTime = frame.decodeTime
            }
        }
        let retainedSubmittedFrameCount = max(0, pendingFrameCount - unsubmittedPendingFrameCount)
        let pendingFrameAgeMs = pendingFrameAgeMsLocked(state: state, now: now)
        let oldestUnsubmittedAgeMs = oldestUnsubmittedDecodeTime
            .map { max(0, now - $0) * 1000 } ?? 0
        let newestUnsubmittedAgeMs = newestUnsubmittedDecodeTime
            .map { max(0, now - $0) * 1000 } ?? 0
        let overwrittenPendingFrames = state.overwrittenPendingFramesSinceLastSnapshot
        let lowestLatencyFreshBacklogDrops = state.lowestLatencyFreshBacklogDropsSinceLastSnapshot
        let lateFrameDrops = state.lateFrameDropsSinceLastSnapshot
        let coalescedBeforeSubmitCount = state.coalescedFramesSinceLastSnapshot
        let duplicateRemoteTimestampCount = state.duplicateRemoteTimestampsSinceLastSnapshot
        let correctedStreamTimestampCount = state.correctedStreamTimestampsSinceLastSnapshot
        let displayLayerNotReadyCount = state.displayLayerNotReadyCountSinceLastSnapshot
        let sampleBufferRendererNotReadyCount = state.sampleBufferRendererNotReadyCountSinceLastSnapshot
        let displayImmediatelySubmittedCount = state.displayImmediatelySubmittedCountSinceLastSnapshot
        let rendererReadyDrainPassCount = state.rendererReadyDrainPassCountSinceLastSnapshot
        let rendererReadyDrainSubmittedCount = state.rendererReadyDrainSubmittedCountSinceLastSnapshot
        let rendererReadyRearmCount = state.rendererReadyRearmCountSinceLastSnapshot
        let repeatedFrameCount = state.repeatedFrameCountSinceLastSnapshot
        let displayTickNoFrameCount = state.displayTickNoFrameCountSinceLastSnapshot
        let tickNoEligibleFrameCount = displayTickNoFrameCount
        let frameArrivedAfterNoFrameTickCount = state.frameArrivedAfterNoFrameTickCountSinceLastSnapshot
        let frameArrivalFallbackCount = state.frameArrivalFallbackCountSinceLastSnapshot
        let frameArrivalFallbackScheduledCount = frameArrivalFallbackCount
        let frameArrivalFallbackSubmittedCount = state.frameArrivalFallbackSubmittedCountSinceLastSnapshot
        let noFrameTickToFrameArrivalMaxMs = state.noFrameTickToFrameArrivalMaxMsSinceLastSnapshot
        let missedVSyncCount = state.missedVSyncCountSinceLastSnapshot
        let smoothestOneFrameHoldCount = state.smoothestOneFrameHoldCountSinceLastSnapshot
        let displayCadenceBelowSourceCount = state.displayCadenceBelowSourceCountSinceLastSnapshot
        let displayTickMainDelayMaxMs = state.displayTickMainDelayMaxMsSinceLastSnapshot
        let renderWorkerSubmitDelayMaxMs = state.renderWorkerSubmitDelayMaxMsSinceLastSnapshot
        let presentationStallCount = state.presentationStallCountSinceLastSnapshot
        let worstPresentationGapMs = state.worstPresentationGapMsSinceLastSnapshot
        let visiblePresentationStallCount = state.visiblePresentationStallCountSinceLastSnapshot
        let visibleWorstPresentationGapMs = state.visibleWorstPresentationGapMsSinceLastSnapshot
        let repeatedSourceFrameCount = state.repeatedSourceFrameCountSinceLastSnapshot
        let intervalSamples = Array(state.frameIntervalSamples[state.frameIntervalSampleStartIndex...].map(\.intervalMs))
        let frameIntervalP95Ms = percentile(intervalSamples, percentile: 0.95)
        let frameIntervalP99Ms = percentile(intervalSamples, percentile: 0.99)
        let frameIntervalMaxMs = intervalSamples.max() ?? 0
        let visibleFrameIntervalSamples = Array(
            state.visibleFrameIntervalSamples[state.visibleFrameIntervalSampleStartIndex...].map(\.intervalMs)
        )
        let visibleFrameIntervalP95Ms = percentile(visibleFrameIntervalSamples, percentile: 0.95)
        let visibleFrameIntervalP99Ms = percentile(visibleFrameIntervalSamples, percentile: 0.99)
        let visibleFrameIntervalMaxMs = visibleFrameIntervalSamples.max() ?? 0
        let displayTickIntervalSamples = Array(
            state.displayTickIntervalSamples[state.displayTickIntervalSampleStartIndex...].map(\.intervalMs)
        )
        let displayTickIntervalP95Ms = percentile(displayTickIntervalSamples, percentile: 0.95)
        let displayTickIntervalP99Ms = percentile(displayTickIntervalSamples, percentile: 0.99)
        let displayTickIntervalMaxMs = displayTickIntervalSamples.max() ?? 0
        let playoutDelayFrames = effectivePlayoutDelayFramesLocked(state: state)
        state.overwrittenPendingFramesSinceLastSnapshot = 0
        state.lowestLatencyFreshBacklogDropsSinceLastSnapshot = 0
        state.lateFrameDropsSinceLastSnapshot = 0
        state.coalescedFramesSinceLastSnapshot = 0
        state.framesSubmittedPerPassTotalSinceLastSnapshot = 0
        state.presentationPassCountSinceLastSnapshot = 0
        state.framesSubmittedPerPassMaxSinceLastSnapshot = 0
        state.duplicateRemoteTimestampsSinceLastSnapshot = 0
        state.correctedStreamTimestampsSinceLastSnapshot = 0
        state.displayLayerNotReadyCountSinceLastSnapshot = 0
        state.sampleBufferRendererNotReadyCountSinceLastSnapshot = 0
        state.displayImmediatelySubmittedCountSinceLastSnapshot = 0
        state.rendererReadyDrainPassCountSinceLastSnapshot = 0
        state.rendererReadyDrainSubmittedCountSinceLastSnapshot = 0
        state.rendererReadyRearmCountSinceLastSnapshot = 0
        state.repeatedFrameCountSinceLastSnapshot = 0
        state.displayTickNoFrameCountSinceLastSnapshot = 0
        state.frameArrivedAfterNoFrameTickCountSinceLastSnapshot = 0
        state.frameArrivalFallbackCountSinceLastSnapshot = 0
        state.frameArrivalFallbackSubmittedCountSinceLastSnapshot = 0
        state.noFrameTickToFrameArrivalMaxMsSinceLastSnapshot = 0
        state.missedVSyncCountSinceLastSnapshot = 0
        state.smoothestOneFrameHoldCountSinceLastSnapshot = 0
        state.displayCadenceBelowSourceCountSinceLastSnapshot = 0
        state.displayTickMainDelayMaxMsSinceLastSnapshot = 0
        state.renderWorkerSubmitDelayMaxMsSinceLastSnapshot = 0
        state.presentationStallCountSinceLastSnapshot = 0
        state.worstPresentationGapMsSinceLastSnapshot = 0
        state.visiblePresentationStallCountSinceLastSnapshot = 0
        state.visibleWorstPresentationGapMsSinceLastSnapshot = 0
        state.repeatedSourceFrameCountSinceLastSnapshot = 0

        let sourceTargetFPS = max(1, state.sourceTargetFPS)
        let displayTargetFPS = max(1, state.displayTargetFPS)
        let decodeRatio = decodeFPS / Double(sourceTargetFPS)
        let decodeHealthy = decodeRatio >= MirageRenderModePolicy.healthyDecodeRatio
        let severeDecodeUnderrun = decodeRatio < MirageRenderModePolicy.stressedDecodeRatio
        state.lock.unlock()

        return RenderTelemetrySnapshot(
            decodeFPS: decodeFPS,
            renderStoreEnqueueFPS: decodeFPS,
            displayLinkCallbackFPS: displayLinkCallbackFPS,
            displayTickWorkerFPS: displayTickWorkerFPS,
            displayTickMainRelayFPS: displayTickMainRelayFPS,
            displayTickFPS: displayTickFPS,
            presentationPassFPS: presentationPassFPS,
            presentationEligibleFPS: presentationEligibleFPS,
            submitAttemptFPS: submitAttemptFPS,
            layerEnqueueFPS: layerEnqueueFPS,
            uniqueLayerEnqueueFPS: uniqueLayerEnqueueFPS,
            visibleFrameFPS: visibleFrameFPS,
            visibleFrameCadenceKnown: visibleFrameCadenceKnown,
            visiblePresentationStallCount: visiblePresentationStallCount,
            visibleWorstPresentationGapMs: visibleWorstPresentationGapMs,
            visibleFrameIntervalP95Ms: visibleFrameIntervalP95Ms,
            visibleFrameIntervalP99Ms: visibleFrameIntervalP99Ms,
            visibleFrameIntervalMaxMs: visibleFrameIntervalMaxMs,
            repeatedSourceFrameCount: repeatedSourceFrameCount,
            framesSubmittedPerPassAverage: framesSubmittedPerPassAverage,
            framesSubmittedPerPassMax: framesSubmittedPerPassMax,
            pendingFrameCount: pendingFrameCount,
            unsubmittedPendingFrameCount: unsubmittedPendingFrameCount,
            retainedSubmittedFrameCount: retainedSubmittedFrameCount,
            pendingFrameAgeMs: pendingFrameAgeMs,
            oldestUnsubmittedAgeMs: oldestUnsubmittedAgeMs,
            newestUnsubmittedAgeMs: newestUnsubmittedAgeMs,
            overwrittenPendingFrames: overwrittenPendingFrames,
            renderStoreOverwriteFPS: renderStoreOverwriteFPS,
            lowestLatencyFreshBacklogDrops: lowestLatencyFreshBacklogDrops,
            lateFrameDrops: lateFrameDrops,
            coalescedBeforeSubmitCount: coalescedBeforeSubmitCount,
            duplicateRemoteTimestampCount: duplicateRemoteTimestampCount,
            correctedStreamTimestampCount: correctedStreamTimestampCount,
            displayLayerNotReadyCount: displayLayerNotReadyCount,
            sampleBufferRendererNotReadyCount: sampleBufferRendererNotReadyCount,
            displayImmediatelySubmittedCount: displayImmediatelySubmittedCount,
            rendererReadyDrainPassCount: rendererReadyDrainPassCount,
            rendererReadyDrainSubmittedCount: rendererReadyDrainSubmittedCount,
            rendererReadyRearmCount: rendererReadyRearmCount,
            repeatedFrameCount: repeatedFrameCount,
            displayTickNoFrameCount: displayTickNoFrameCount,
            tickNoEligibleFrameCount: tickNoEligibleFrameCount,
            frameArrivedAfterNoFrameTickCount: frameArrivedAfterNoFrameTickCount,
            frameArrivalFallbackCount: frameArrivalFallbackCount,
            frameArrivalFallbackScheduledCount: frameArrivalFallbackScheduledCount,
            frameArrivalFallbackSubmittedCount: frameArrivalFallbackSubmittedCount,
            noFrameTickToFrameArrivalMaxMs: noFrameTickToFrameArrivalMaxMs,
            missedVSyncCount: missedVSyncCount,
            smoothestOneFrameHoldCount: smoothestOneFrameHoldCount,
            displayCadenceBelowSourceCount: displayCadenceBelowSourceCount,
            displayTickIntervalP95Ms: displayTickIntervalP95Ms,
            displayTickIntervalP99Ms: displayTickIntervalP99Ms,
            playoutDelayFrames: playoutDelayFrames,
            presentationStallCount: presentationStallCount,
            worstPresentationGapMs: worstPresentationGapMs,
            frameIntervalP95Ms: frameIntervalP95Ms,
            frameIntervalP99Ms: frameIntervalP99Ms,
            frameIntervalMaxMs: frameIntervalMaxMs,
            displayTickIntervalMaxMs: displayTickIntervalMaxMs,
            displayTickMainDelayMaxMs: displayTickMainDelayMaxMs,
            renderWorkerSubmitDelayMaxMs: renderWorkerSubmitDelayMaxMs,
            decodeHealthy: decodeHealthy,
            severeDecodeUnderrun: severeDecodeUnderrun,
            sourceTargetFPS: sourceTargetFPS,
            displayTargetFPS: displayTargetFPS,
            targetFPS: sourceTargetFPS
        )
    }

    func feedbackTelemetrySnapshot(for streamID: StreamID) -> FeedbackTelemetrySnapshot {
        guard let state = streamStateIfPresent(for: streamID) else {
            return FeedbackTelemetrySnapshot(
                pendingFrameCount: 0,
                layerEnqueueFPS: 0,
                uniqueLayerEnqueueFPS: 0,
                visibleFrameFPS: 0,
                visibleFrameCadenceKnown: false
            )
        }

        state.lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        trimSamplesLocked(now: now, samples: &state.submittedSamples, startIndex: &state.submittedSampleStartIndex)
        trimSamplesLocked(
            now: now,
            samples: &state.uniqueSubmittedSamples,
            startIndex: &state.uniqueSubmittedSampleStartIndex
        )
        trimSamplesLocked(
            now: now,
            samples: &state.visibleFrameSamples,
            startIndex: &state.visibleFrameSampleStartIndex
        )
        let snapshot = FeedbackTelemetrySnapshot(
            pendingFrameCount: state.pendingFrames.count,
            layerEnqueueFPS: Double(state.submittedSamples.count - state.submittedSampleStartIndex),
            uniqueLayerEnqueueFPS: Double(state.uniqueSubmittedSamples.count - state.uniqueSubmittedSampleStartIndex),
            visibleFrameFPS: Double(state.visibleFrameSamples.count - state.visibleFrameSampleStartIndex),
            visibleFrameCadenceKnown: state.lastVisibleFrameTime > 0
        )
        state.lock.unlock()
        return snapshot
    }

    func presentationTiming(for streamID: StreamID) -> MirageRenderPresentationTiming {
        let state = streamState(for: streamID)
        state.lock.lock()
        let timing = MirageRenderPresentationTiming(
            targetFPS: state.sourceTargetFPS,
            playoutDelayFrames: effectivePlayoutDelayFramesLocked(state: state)
        )
        state.lock.unlock()
        return timing
    }

    func setTargetFPS(for streamID: StreamID, targetFPS: Int) {
        let state = streamState(for: streamID)
        state.lock.lock()
        let normalized = MirageRenderModePolicy.normalizedTargetFPS(targetFPS)
        state.sourceTargetFPS = normalized
        state.displayTargetFPS = normalized
        state.playoutDelayFrames = MirageRenderModePolicy.playoutDelayFrames(for: state.latencyMode)
        trimPendingFramesToCapacityLocked(state: state, now: CFAbsoluteTimeGetCurrent())
        state.lock.unlock()
    }

    func setCadenceTarget(for streamID: StreamID, target: MirageStreamCadenceTarget) {
        let state = streamState(for: streamID)
        state.lock.lock()
        state.sourceTargetFPS = target.sourceFPS
        state.displayTargetFPS = target.displayFPS
        state.latencyMode = target.latencyMode
        state.playoutDelayFrames = target.playoutDelayFrames
        trimPendingFramesToCapacityLocked(state: state, now: CFAbsoluteTimeGetCurrent())
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
        state.playoutDelayFrames = MirageRenderModePolicy.playoutDelayFrames(for: latencyMode)
        trimPendingFramesToCapacityLocked(state: state, now: CFAbsoluteTimeGetCurrent())
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
        state.presentationRecoveryRequestCount &+= 1
        state.presentationRecoveryHandlerDispatchCount &+= UInt64(callbacks.count)
        state.lastPresentationRecoveryOutcome = callbacks.isEmpty ? "noHandlers" : "dispatched:\(callbacks.count)"
        state.lock.unlock()

        for callback in callbacks {
            callback()
        }

        return !callbacks.isEmpty
    }

    @discardableResult
    func bumpGeneration(for streamID: StreamID, reason: String? = nil) -> UInt64 {
        stateLock.lock()
        let state = streams[streamID]
        let previousGeneration = generationByStreamID[streamID] ?? state?.generation ?? initialGeneration
        let nextGeneration = previousGeneration &+ 1
        generationByStreamID[streamID] = nextGeneration

        guard let state else {
            stateLock.unlock()
            if let reason {
                MirageLogger.renderer("Render generation advanced for stream \(streamID) to \(nextGeneration) (\(reason))")
            }
            return nextGeneration
        }

        state.lock.lock()
        state.generationBumpCount &+= 1
        state.lastGenerationBumpReason = reason ?? "unspecified"
        resetLocked(state: state, generation: nextGeneration)
        state.lock.unlock()
        stateLock.unlock()

        if let reason {
            MirageLogger.renderer("Render generation advanced for stream \(streamID) to \(nextGeneration) (\(reason))")
        }
        return nextGeneration
    }

    func clear(for streamID: StreamID) {
        stateLock.lock()
        let state = streams[streamID]
        let previousGeneration = generationByStreamID[streamID] ?? state?.generation ?? initialGeneration
        let nextGeneration = previousGeneration &+ 1
        generationByStreamID[streamID] = nextGeneration

        guard let state else {
            stateLock.unlock()
            return
        }
        state.lock.lock()
        state.clearCount &+= 1
        state.generationBumpCount &+= 1
        state.lastGenerationBumpReason = "clear"
        resetLocked(state: state, generation: nextGeneration)
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

        let generation = generationByStreamID[streamID] ?? initialGeneration
        generationByStreamID[streamID] = generation
        let created = StreamState(generation: generation)
        streams[streamID] = created
        stateLock.unlock()
        return created
    }

    private static func reasonSummary(_ counts: [String: UInt64]) -> String? {
        guard !counts.isEmpty else { return nil }
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }

    private func streamStateIfPresent(for streamID: StreamID) -> StreamState? {
        stateLock.lock()
        let state = streams[streamID]
        stateLock.unlock()
        return state
    }

    private func resetLocked(state: StreamState, generation: UInt64) {
        state.generation = generation
        state.pendingFrames.removeAll(keepingCapacity: false)
        state.nextSequence = 0
        state.lastSubmittedSequence = 0
        state.lastSubmittedTime = 0
        state.lastSubmittedRemotePresentationTime = .invalid
        state.lastSubmittedMappedPresentationTime = .invalid
        state.lastAcceptedFrameTimeline = nil
        state.lastDisplayTickTime = 0
        state.decodeSamples.removeAll(keepingCapacity: false)
        state.decodeSampleStartIndex = 0
        state.displayLinkCallbackSamples.removeAll(keepingCapacity: false)
        state.displayLinkCallbackSampleStartIndex = 0
        state.displayTickWorkerSamples.removeAll(keepingCapacity: false)
        state.displayTickWorkerSampleStartIndex = 0
        state.displayTickMainRelaySamples.removeAll(keepingCapacity: false)
        state.displayTickMainRelaySampleStartIndex = 0
        state.displayTickSamples.removeAll(keepingCapacity: false)
        state.displayTickSampleStartIndex = 0
        state.presentationPassSamples.removeAll(keepingCapacity: false)
        state.presentationPassSampleStartIndex = 0
        state.presentationEligibleSamples.removeAll(keepingCapacity: false)
        state.presentationEligibleSampleStartIndex = 0
        state.submitAttemptSamples.removeAll(keepingCapacity: false)
        state.submitAttemptSampleStartIndex = 0
        state.renderStoreOverwriteSamples.removeAll(keepingCapacity: false)
        state.renderStoreOverwriteSampleStartIndex = 0
        state.submittedSamples.removeAll(keepingCapacity: false)
        state.submittedSampleStartIndex = 0
        state.uniqueSubmittedSamples.removeAll(keepingCapacity: false)
        state.uniqueSubmittedSampleStartIndex = 0
        state.visibleFrameSamples.removeAll(keepingCapacity: false)
        state.visibleFrameSampleStartIndex = 0
        state.frameIntervalSamples.removeAll(keepingCapacity: false)
        state.frameIntervalSampleStartIndex = 0
        state.visibleFrameIntervalSamples.removeAll(keepingCapacity: false)
        state.visibleFrameIntervalSampleStartIndex = 0
        state.displayTickIntervalSamples.removeAll(keepingCapacity: false)
        state.displayTickIntervalSampleStartIndex = 0
        state.overwrittenPendingFramesSinceLastSnapshot = 0
        state.lowestLatencyFreshBacklogDropsSinceLastSnapshot = 0
        state.lateFrameDropsSinceLastSnapshot = 0
        state.coalescedFramesSinceLastSnapshot = 0
        state.framesSubmittedPerPassTotalSinceLastSnapshot = 0
        state.presentationPassCountSinceLastSnapshot = 0
        state.framesSubmittedPerPassMaxSinceLastSnapshot = 0
        state.duplicateRemoteTimestampsSinceLastSnapshot = 0
        state.correctedStreamTimestampsSinceLastSnapshot = 0
        state.displayLayerNotReadyCountSinceLastSnapshot = 0
        state.sampleBufferRendererNotReadyCountSinceLastSnapshot = 0
        state.displayImmediatelySubmittedCountSinceLastSnapshot = 0
        state.rendererReadyDrainPassCountSinceLastSnapshot = 0
        state.rendererReadyDrainSubmittedCountSinceLastSnapshot = 0
        state.rendererReadyRearmCountSinceLastSnapshot = 0
        state.repeatedFrameCountSinceLastSnapshot = 0
        state.displayTickNoFrameCountSinceLastSnapshot = 0
        state.frameArrivedAfterNoFrameTickCountSinceLastSnapshot = 0
        state.frameArrivalFallbackCountSinceLastSnapshot = 0
        state.frameArrivalFallbackSubmittedCountSinceLastSnapshot = 0
        state.noFrameTickToFrameArrivalMaxMsSinceLastSnapshot = 0
        state.missedVSyncCountSinceLastSnapshot = 0
        state.smoothestOneFrameHoldCountSinceLastSnapshot = 0
        state.displayCadenceBelowSourceCountSinceLastSnapshot = 0
        state.displayTickMainDelayMaxMsSinceLastSnapshot = 0
        state.renderWorkerSubmitDelayMaxMsSinceLastSnapshot = 0
        state.presentationStallCountSinceLastSnapshot = 0
        state.worstPresentationGapMsSinceLastSnapshot = 0
        state.visiblePresentationStallCountSinceLastSnapshot = 0
        state.visibleWorstPresentationGapMsSinceLastSnapshot = 0
        state.repeatedSourceFrameCountSinceLastSnapshot = 0
        state.lastPresentedFrameIdentity = nil
        state.lastVisibleFrameTime = 0
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

    private func appendPendingFrameLocked(_ frame: MirageRenderFrame, state: StreamState) -> Int {
        let now = CFAbsoluteTimeGetCurrent()
        state.pendingFrames.append(frame)

        let overwrittenPendingFrames = trimPendingFramesToCapacityCountLocked(
            state: state,
            now: now
        )
        if overwrittenPendingFrames > 0 {
            state.overwrittenPendingFramesSinceLastSnapshot &+= UInt64(overwrittenPendingFrames)
            state.coalescedFramesSinceLastSnapshot &+= UInt64(overwrittenPendingFrames)
        }
        return overwrittenPendingFrames
    }

    private func trimPendingFramesToCapacityLocked(state: StreamState, now: CFAbsoluteTime) {
        let overwrittenPendingFrames = trimPendingFramesToCapacityCountLocked(state: state, now: now)
        if overwrittenPendingFrames > 0 {
            state.overwrittenPendingFramesSinceLastSnapshot &+= UInt64(overwrittenPendingFrames)
            state.coalescedFramesSinceLastSnapshot &+= UInt64(overwrittenPendingFrames)
        }
    }

    private func trimPendingFramesToCapacityCountLocked(state: StreamState, now: CFAbsoluteTime) -> Int {
        var overwrittenPendingFrames = 0
        while state.pendingFrames.count > pendingFrameCapacityLocked(state: state, now: now) {
            state.pendingFrames.removeFirst()
            appendSampleLocked(
                now,
                samples: &state.renderStoreOverwriteSamples,
                startIndex: &state.renderStoreOverwriteSampleStartIndex
            )
            overwrittenPendingFrames += 1
        }
        overwrittenPendingFrames += trimPendingFramesToTargetDepthWhenStaleLocked(state: state, now: now)
        return overwrittenPendingFrames
    }

    private func trimPendingFramesForSelectionLocked(state: StreamState, now: CFAbsoluteTime) -> Int {
        trimPendingFramesToTargetDepthWhenStaleLocked(state: state, now: now)
    }

    private func trimPendingFramesToTargetDepthWhenStaleLocked(
        state: StreamState,
        now: CFAbsoluteTime
    ) -> Int {
        if state.latencyMode == .lowestLatency {
            return trimLowestLatencyPendingFramesLocked(state: state, now: now)
        }

        let targetDepth = targetPendingFrameDepthLocked(state: state, now: now)
        guard state.pendingFrames.count > targetDepth else { return 0 }

        let freshnessWindow = freshInOrderBurstWindowLocked(state: state, now: now)
        var droppedFrames = 0
        while state.pendingFrames.count > targetDepth,
              let first = state.pendingFrames.first,
              now - first.decodeTime > freshnessWindow {
            state.pendingFrames.removeFirst()
            appendSampleLocked(
                now,
                samples: &state.renderStoreOverwriteSamples,
                startIndex: &state.renderStoreOverwriteSampleStartIndex
            )
            if state.latencyMode == .lowestLatency {
                state.lowestLatencyFreshBacklogDropsSinceLastSnapshot &+= 1
            }
            droppedFrames += 1
        }
        return droppedFrames
    }

    private func pendingFrameCapacityLocked(state: StreamState, now: CFAbsoluteTime) -> Int {
        let targetDepth = targetPendingFrameDepthLocked(state: state, now: now)

        if state.latencyMode == .lowestLatency {
            return min(lowestLatencyMaximumPendingFrames, targetDepth)
        }

        return max(
            targetDepth,
            freshBurstCapacityFramesLocked(state: state)
        )
    }

    private func targetPendingFrameDepthLocked(state: StreamState, now: CFAbsoluteTime) -> Int {
        max(1, effectivePlayoutDelayFramesLocked(state: state) + 1)
    }

    private func freshInOrderBurstWindowLocked(state: StreamState, now: CFAbsoluteTime) -> CFAbsoluteTime {
        let sourceFPS = max(1, state.sourceTargetFPS)
        let frameInterval = 1 / CFAbsoluteTime(sourceFPS)
        if state.latencyMode == .lowestLatency {
            return frameInterval
        }

        let capacityFrames = max(
            targetPendingFrameDepthLocked(state: state, now: now),
            freshBurstCapacityFramesLocked(state: state)
        )
        let capacityWindow = frameInterval * CFAbsoluteTime(capacityFrames)
        let burstWindow = smoothestFreshBurstWindowSeconds
        return max(frameInterval, min(burstWindow, capacityWindow))
    }

    private func freshBurstCapacityFramesLocked(state: StreamState) -> Int {
        if state.latencyMode == .lowestLatency {
            return lowestLatencyMaximumPendingFrames
        }

        let sourceFPS = max(1, state.sourceTargetFPS)
        let burstWindow = smoothestFreshBurstWindowSeconds
        let maximumFrames = smoothestFreshBurstMaximumFrames
        let freshBurstFrames = Int(ceil(Double(sourceFPS) * burstWindow))
        return max(1, min(maximumFrames, freshBurstFrames))
    }

    private func trimLowestLatencyPendingFramesLocked(state: StreamState, now: CFAbsoluteTime) -> Int {
        var droppedFrames = 0
        while state.pendingFrames.count > lowestLatencyMaximumPendingFrames {
            state.pendingFrames.removeFirst()
            appendSampleLocked(
                now,
                samples: &state.renderStoreOverwriteSamples,
                startIndex: &state.renderStoreOverwriteSampleStartIndex
            )
            state.lowestLatencyFreshBacklogDropsSinceLastSnapshot &+= 1
            droppedFrames += 1
        }

        guard let frame = state.pendingFrames.first else { return droppedFrames }
        let sourceFPS = max(1, state.sourceTargetFPS)
        let frameInterval = 1 / CFAbsoluteTime(sourceFPS)
        let staleFrameWindow = max(frameInterval * 2, frameInterval + 0.004)
        guard now - frame.decodeTime > staleFrameWindow else { return droppedFrames }

        state.pendingFrames.removeFirst()
        appendSampleLocked(
            now,
            samples: &state.renderStoreOverwriteSamples,
            startIndex: &state.renderStoreOverwriteSampleStartIndex
        )
        state.lowestLatencyFreshBacklogDropsSinceLastSnapshot &+= 1
        return droppedFrames + 1
    }

    private func effectivePlayoutDelayFramesLocked(state: StreamState) -> Int {
        let baseDelayFrames = max(0, state.playoutDelayFrames)
        return min(baseDelayFrames, MirageRenderModePolicy.maximumSmoothestPlayoutDelayFrames)
    }

    private func displayCadenceBelowSourceLocked(state: StreamState) -> Bool {
        let intervals = state.displayTickIntervalSamples[state.displayTickIntervalSampleStartIndex...].map(\.intervalMs)
        guard !intervals.isEmpty else { return false }

        let sourceFPS = max(1, state.sourceTargetFPS)
        let averageIntervalMs = intervals.reduce(0, +) / Double(intervals.count)
        guard averageIntervalMs > 0 else { return false }

        let measuredDisplayFPS = 1_000 / averageIntervalMs
        return measuredDisplayFPS < Double(sourceFPS) * 0.9
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
        guard let decodeTime = state.pendingFrames.first?.decodeTime else { return 0 }
        return max(0, now - decodeTime) * 1000
    }

}
