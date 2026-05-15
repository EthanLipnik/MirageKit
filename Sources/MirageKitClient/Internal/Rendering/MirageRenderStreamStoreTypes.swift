//
//  MirageRenderStreamStoreTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Latest-frame render store state and telemetry carriers.
//

import CoreMedia
import Foundation
import MirageKit

struct SubmissionSnapshot {
    /// Last frame sequence accepted by the presentation layer.
    let sequence: UInt64

    /// Wall-clock time when the frame was submitted.
    let submittedTime: CFAbsoluteTime

    /// Host-provided presentation timestamp for the submitted frame, when available.
    let remotePresentationTime: CMTime
}

struct MirageRenderEnqueueResult {
    let cursor: MirageRenderCursor
    let didEnqueue: Bool
    let pendingFrameCount: Int
    let pendingFrameAgeMs: Double
    let overwrittenPendingFrames: Int
}

/// Rolling render telemetry sampled by stream UI and diagnostics.
struct RenderTelemetrySnapshot {
    /// Display clock ticks observed during the one-second telemetry window.
    let displayTickFPS: Double

    /// Presentation attempts made during the one-second telemetry window.
    let submitAttemptFPS: Double

    /// Frames accepted by the display layer during the one-second telemetry window.
    let layerAcceptedFPS: Double

    /// Unique frames presented during the one-second telemetry window.
    let presentedFPS: Double

    /// Total display-layer submissions during the one-second telemetry window.
    let submittedFPS: Double

    /// Unique frame submissions, excluding repeated ticks that reused the last frame.
    let uniqueSubmittedFPS: Double

    /// Frames currently queued for presentation.
    let pendingFrameCount: Int

    /// Age of the oldest pending frame in milliseconds.
    let pendingFrameAgeMs: Double

    /// Pending frames overwritten because the local playout queue was full.
    let overwrittenPendingFrames: UInt64

    /// Smoothest-mode frames dropped by local playout queue bounds.
    let smoothestQueueDrops: UInt64

    /// Queued frames dropped because newer frames had already superseded them.
    let lateFrameDrops: UInt64

    /// Frames coalesced before presentation.
    let coalescedBeforeSubmitCount: UInt64

    /// Frames received with a duplicate host presentation timestamp.
    let duplicateRemoteTimestampCount: UInt64

    /// Frames whose host timestamp required local monotonic correction.
    let correctedStreamTimestampCount: UInt64

    /// Times presentation was attempted while the display layer was not ready.
    let displayLayerNotReadyCount: UInt64

    /// Display ticks that repeated the previous submitted frame.
    let repeatedFrameCount: UInt64

    let displayTickNoFrameCount: UInt64
    let frameArrivedAfterNoFrameTickCount: UInt64
    let frameArrivalFallbackCount: UInt64
    let frameArrivalFallbackScheduledCount: UInt64
    let frameArrivalFallbackSubmittedCount: UInt64
    let noFrameTickToFrameArrivalMaxMs: Double

    /// Display intervals that exceeded the target frame duration threshold.
    let missedVSyncCount: UInt64

    /// 95th percentile display-clock interval in milliseconds.
    let displayTickIntervalP95Ms: Double

    /// 99th percentile display-clock interval in milliseconds.
    let displayTickIntervalP99Ms: Double

    /// Current playout delay target in frames.
    let playoutDelayFrames: Int

    /// Whether submitted sample buffers are marked for immediate display.
    let displaysImmediately: Bool

    /// Current target depth used by smoothest live-edge/cushion decisions.
    let queueTargetDepth: Int

    /// Current effective presentation mode.
    let presentationMode: MiragePresentationDecisionMode

    /// Presentation gaps counted as stalls since the previous snapshot.
    let presentationStallCount: UInt64

    /// Longest presentation gap in milliseconds since the previous snapshot.
    let worstPresentationGapMs: Double

    /// 95th percentile unique-frame submission interval in milliseconds.
    let frameIntervalP95Ms: Double

    /// 99th percentile unique-frame submission interval in milliseconds.
    let frameIntervalP99Ms: Double

    /// Whether decode throughput is high enough for the current source frame rate.
    let decodeHealthy: Bool
}

/// Weak owner token used to drop render-frame listeners after their owner deallocates.
final class MirageRenderStreamWeakOwner {
    weak var value: AnyObject?

    init(_ value: AnyObject) {
        self.value = value
    }
}

struct MirageRenderStreamFrameListener {
    /// Weak owner that controls listener lifetime.
    let owner: MirageRenderStreamWeakOwner

    /// Callback invoked when the store has work for the listener.
    let callback: @Sendable () -> Void
}

/// Locked mutable render state for one media stream.
final class MirageRenderStreamState {
    /// Protects all mutable fields in this state object.
    let lock = NSLock()
    var generation: UInt64 = 0
    var pendingFrames: [MirageRenderFrame] = []
    var presentationController = MirageClientPresentationController()
    var nextSequence: UInt64 = 0
    var lastSubmittedGeneration: UInt64 = 0
    var lastSubmittedSequence: UInt64 = 0
    var lastSubmittedTime: CFAbsoluteTime = 0
    var lastSelectedFrameNumber: UInt32?
    var lastSubmittedFrameNumber: UInt32?
    var lastSubmittedRemotePresentationTime: CMTime = .invalid
    var lastSubmittedMappedPresentationTime: CMTime = .invalid
    var lastAcceptedFrameTimeline: FrameTimeline?
    var lastDisplayTickTime: CFAbsoluteTime = 0
    var sourceTargetFPS: Int = 60
    var displayTargetFPS: Int = 60
    var latencyMode: MirageStreamLatencyMode = .lowestLatency
    var playoutDelayFrames: Int = 0
    var displaysImmediately: Bool = true
    var queueTargetDepth: Int = 1
    var presentationMode: MiragePresentationDecisionMode = .lowestLatency
    var smoothestPlayoutController = MirageSmoothestPlayoutController()
    var listeners: [ObjectIdentifier: MirageRenderStreamFrameListener] = [:]
    var presentationRecoveryHandlers: [ObjectIdentifier: MirageRenderStreamFrameListener] = [:]

    var decodeSamples: [CFAbsoluteTime] = []
    var decodeSampleStartIndex: Int = 0
    var displayTickSamples: [CFAbsoluteTime] = []
    var displayTickSampleStartIndex: Int = 0
    var submitAttemptSamples: [CFAbsoluteTime] = []
    var submitAttemptSampleStartIndex: Int = 0
    var submittedSamples: [CFAbsoluteTime] = []
    var submittedSampleStartIndex: Int = 0
    var uniqueSubmittedSamples: [CFAbsoluteTime] = []
    var uniqueSubmittedSampleStartIndex: Int = 0
    var frameIntervalSamples: [(time: CFAbsoluteTime, intervalMs: Double)] = []
    var frameIntervalSampleStartIndex: Int = 0
    var displayTickIntervalSamples: [(time: CFAbsoluteTime, intervalMs: Double)] = []
    var displayTickIntervalSampleStartIndex: Int = 0

    var overwrittenPendingFramesSinceLastSnapshot: UInt64 = 0
    var smoothestQueueDropsSinceLastSnapshot: UInt64 = 0
    var lateFrameDropsSinceLastSnapshot: UInt64 = 0
    var coalescedFramesSinceLastSnapshot: UInt64 = 0
    var duplicateRemoteTimestampsSinceLastSnapshot: UInt64 = 0
    var correctedStreamTimestampsSinceLastSnapshot: UInt64 = 0
    var displayLayerNotReadyCountSinceLastSnapshot: UInt64 = 0
    var repeatedFrameCountSinceLastSnapshot: UInt64 = 0
    var displayTickNoFrameCountSinceLastSnapshot: UInt64 = 0
    var frameArrivedAfterNoFrameTickCountSinceLastSnapshot: UInt64 = 0
    var frameArrivalFallbackCountSinceLastSnapshot: UInt64 = 0
    var frameArrivalFallbackScheduledCountSinceLastSnapshot: UInt64 = 0
    var frameArrivalFallbackSubmittedCountSinceLastSnapshot: UInt64 = 0
    var noFrameTickToFrameArrivalMaxMsSinceLastSnapshot: Double = 0
    var missedVSyncCountSinceLastSnapshot: UInt64 = 0
    var presentationStallCountSinceLastSnapshot: UInt64 = 0
    var worstPresentationGapMsSinceLastSnapshot: Double = 0

    /// Clears queued frames, submission state, and rolling telemetry while retaining live listener registrations.
    func resetFramesAndTelemetryLocked() {
        pendingFrames.removeAll(keepingCapacity: false)
        generation &+= 1
        nextSequence = 0
        lastSubmittedGeneration = generation
        lastSubmittedSequence = 0
        lastSubmittedTime = 0
        lastSelectedFrameNumber = nil
        lastSubmittedFrameNumber = nil
        lastSubmittedRemotePresentationTime = .invalid
        lastSubmittedMappedPresentationTime = .invalid
        lastAcceptedFrameTimeline = nil
        lastDisplayTickTime = 0
        playoutDelayFrames = 0
        displaysImmediately = true
        queueTargetDepth = 1
        presentationMode = .lowestLatency
        smoothestPlayoutController.reset()
        decodeSamples.removeAll(keepingCapacity: false)
        decodeSampleStartIndex = 0
        displayTickSamples.removeAll(keepingCapacity: false)
        displayTickSampleStartIndex = 0
        submitAttemptSamples.removeAll(keepingCapacity: false)
        submitAttemptSampleStartIndex = 0
        submittedSamples.removeAll(keepingCapacity: false)
        submittedSampleStartIndex = 0
        uniqueSubmittedSamples.removeAll(keepingCapacity: false)
        uniqueSubmittedSampleStartIndex = 0
        frameIntervalSamples.removeAll(keepingCapacity: false)
        frameIntervalSampleStartIndex = 0
        displayTickIntervalSamples.removeAll(keepingCapacity: false)
        displayTickIntervalSampleStartIndex = 0
        overwrittenPendingFramesSinceLastSnapshot = 0
        smoothestQueueDropsSinceLastSnapshot = 0
        lateFrameDropsSinceLastSnapshot = 0
        coalescedFramesSinceLastSnapshot = 0
        duplicateRemoteTimestampsSinceLastSnapshot = 0
        correctedStreamTimestampsSinceLastSnapshot = 0
        displayLayerNotReadyCountSinceLastSnapshot = 0
        repeatedFrameCountSinceLastSnapshot = 0
        displayTickNoFrameCountSinceLastSnapshot = 0
        frameArrivedAfterNoFrameTickCountSinceLastSnapshot = 0
        frameArrivalFallbackCountSinceLastSnapshot = 0
        frameArrivalFallbackScheduledCountSinceLastSnapshot = 0
        frameArrivalFallbackSubmittedCountSinceLastSnapshot = 0
        noFrameTickToFrameArrivalMaxMsSinceLastSnapshot = 0
        missedVSyncCountSinceLastSnapshot = 0
        presentationStallCountSinceLastSnapshot = 0
        worstPresentationGapMsSinceLastSnapshot = 0
        listeners = listeners.filter { entry in
            entry.value.owner.value != nil
        }
        presentationRecoveryHandlers = presentationRecoveryHandlers.filter { entry in
            entry.value.owner.value != nil
        }
    }
}
