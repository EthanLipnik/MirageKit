//
//  MirageRenderStreamStoreTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Latest-frame render store state and telemetry carriers.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreMedia
import Foundation

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
    var lastSubmittedDimensionToken: UInt16?
    var lastEnqueuedHostEpoch: UInt16?
    var lastEnqueuedDimensionToken: UInt16?
    var lastSubmittedRemotePresentationTime: CMTime = .invalid
    var lastSubmittedMappedPresentationTime: CMTime = .invalid
    var lastAcceptedFrameTimeline: MirageDiagnostics.FrameTimeline?
    var lastDisplayTickTime: CFAbsoluteTime = 0
    var sourceTargetFPS: Int = 60
    var displayTargetFPS: Int = 60
    var latencyMode: MirageMedia.MirageStreamLatencyMode = .lowestLatency
    var playoutDelayFrames: Int = MirageMedia.MirageStreamCadenceTarget.defaultPlayoutDelayFrames(for: .lowestLatency)
    var transportPathKind: MirageCore.MirageNetworkPathKind = .unknown
    var mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown
    var awdlReceiverPlayoutDelayTargetMs: Double?
    var lastInteractionTime: CFAbsoluteTime = 0
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
    var pendingFrameAgeSamples: [(time: CFAbsoluteTime, value: Double)] = []
    var pendingFrameAgeSampleStartIndex: Int = 0
    var pendingFrameDepthSamples: [(time: CFAbsoluteTime, value: Double)] = []
    var pendingFrameDepthSampleStartIndex: Int = 0

    var overwrittenPendingFramesSinceLastSnapshot: UInt64 = 0
    var smoothestQueueDropsSinceLastSnapshot: UInt64 = 0
    var smoothestDepthDropsSinceLastSnapshot: UInt64 = 0
    var smoothestAgeDropsSinceLastSnapshot: UInt64 = 0
    var smoothestDropsUnder100msSinceLastSnapshot: UInt64 = 0
    var smoothestDroppedFrameAgeMaxMsSinceLastSnapshot: Double = 0
    var smoothestDisplayDebtDropsSinceLastSnapshot: UInt64 = 0
    var smoothestFifoResetCountSinceLastSnapshot: UInt64 = 0
    var lateFrameDropsSinceLastSnapshot: UInt64 = 0
    var coalescedFramesSinceLastSnapshot: UInt64 = 0
    var duplicateRemoteTimestampsSinceLastSnapshot: UInt64 = 0
    var correctedStreamTimestampsSinceLastSnapshot: UInt64 = 0
    var displayLayerNotReadyCountSinceLastSnapshot: UInt64 = 0
    var repeatedFrameCountSinceLastSnapshot: UInt64 = 0
    var displayTickNoFrameCountSinceLastSnapshot: UInt64 = 0
    var pendingFrameNotReadyDisplayTickCountSinceLastSnapshot: UInt64 = 0
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
        presentationController.reset()
        generation &+= 1
        nextSequence = 0
        lastSubmittedGeneration = generation
        lastSubmittedSequence = 0
        lastSubmittedTime = 0
        lastSelectedFrameNumber = nil
        lastSubmittedFrameNumber = nil
        lastSubmittedDimensionToken = nil
        lastEnqueuedHostEpoch = nil
        lastEnqueuedDimensionToken = nil
        lastSubmittedRemotePresentationTime = .invalid
        lastSubmittedMappedPresentationTime = .invalid
        lastAcceptedFrameTimeline = nil
        lastDisplayTickTime = 0
        transportPathKind = .unknown
        mediaPathProfile = .unknown
        awdlReceiverPlayoutDelayTargetMs = nil
        lastInteractionTime = 0
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
        pendingFrameAgeSamples.removeAll(keepingCapacity: false)
        pendingFrameAgeSampleStartIndex = 0
        pendingFrameDepthSamples.removeAll(keepingCapacity: false)
        pendingFrameDepthSampleStartIndex = 0
        overwrittenPendingFramesSinceLastSnapshot = 0
        smoothestQueueDropsSinceLastSnapshot = 0
        smoothestDepthDropsSinceLastSnapshot = 0
        smoothestAgeDropsSinceLastSnapshot = 0
        smoothestDropsUnder100msSinceLastSnapshot = 0
        smoothestDroppedFrameAgeMaxMsSinceLastSnapshot = 0
        smoothestDisplayDebtDropsSinceLastSnapshot = 0
        smoothestFifoResetCountSinceLastSnapshot = 0
        lateFrameDropsSinceLastSnapshot = 0
        coalescedFramesSinceLastSnapshot = 0
        duplicateRemoteTimestampsSinceLastSnapshot = 0
        correctedStreamTimestampsSinceLastSnapshot = 0
        displayLayerNotReadyCountSinceLastSnapshot = 0
        repeatedFrameCountSinceLastSnapshot = 0
        displayTickNoFrameCountSinceLastSnapshot = 0
        pendingFrameNotReadyDisplayTickCountSinceLastSnapshot = 0
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
