//
//  MirageClientMetricsStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
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
import Foundation

/// Thread-safe per-stream telemetry store used by client UI, diagnostics, and recovery policy.
public final class MirageClientMetricsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var metricsByStream: [StreamID: MirageDiagnostics.MirageClientMetricsSnapshot] = [:]

    /// Creates an empty metrics store.
    public init() {}

    /// Updates client-side receive, decode, presentation, and reassembler metrics for one stream.
    ///
    /// Existing host metrics for the same stream are preserved so host and client
    /// telemetry can arrive independently without clobbering each other.
    public func updateClientMetrics(
        streamID: StreamID,
        decodedFPS: Double,
        receivedFPS: Double,
        receivedWorstGapMs: Double = 0,
        receivedFrameIntervalP95Ms: Double = 0,
        receivedFrameIntervalP99Ms: Double = 0,
        receiverIngressJitterP95Ms: Double = 0,
        receiverIngressJitterP99Ms: Double = 0,
        droppedFrames: UInt64,
        decodeBacklogFrames: Int = 0,
        reassemblerPendingFrameCount: Int = 0,
        reassemblerPendingKeyframeCount: Int = 0,
        reassemblerPendingBytes: Int = 0,
        frameBufferPoolRetainedBytes: Int = 0,
        reassemblerBudgetEvictions: UInt64 = 0,
        reassemblerIncompleteFrameTimeouts: UInt64 = 0,
        reassemblerIncompleteFrameNoProgressTimeouts: UInt64 = 0,
        reassemblerIncompleteFrameLifetimeTimeouts: UInt64 = 0,
        reassemblerMissingFragmentTimeouts: UInt64 = 0,
        reassemblerForwardGapTimeouts: UInt64 = 0,
        frameCompletionLatencyP50Ms: Double = 0,
        frameCompletionLatencyP95Ms: Double = 0,
        frameCompletionLatencyMaxMs: Double = 0,
        keyframeCompletionLatencyP50Ms: Double = 0,
        keyframeCompletionLatencyP95Ms: Double = 0,
        keyframeCompletionLatencyMaxMs: Double = 0,
        pFrameCompletionLatencyP50Ms: Double = 0,
        pFrameCompletionLatencyP95Ms: Double = 0,
        pFrameCompletionLatencyMaxMs: Double = 0,
        latePFrameCompletionCount: UInt64 = 0,
        reassemblerFECRecoveredFragmentCount: UInt64 = 0,
        displayTickFPS: Double = 0,
        submitAttemptFPS: Double = 0,
        layerAcceptedFPS: Double = 0,
        presentedFPS: Double = 0,
        submittedFPS: Double,
        uniqueSubmittedFPS: Double,
        pendingFrameCount: Int,
        pendingFrameAgeMs: Double,
        smoothestDisplayDebtMs: Double = 0,
        smoothestDisplayDebtCapMs: Double = 0,
        smoothestTargetDelayMs: Double = 0,
        overwrittenPendingFrames: UInt64,
        smoothestQueueDrops: UInt64 = 0,
        smoothestDisplayDebtDrops: UInt64 = 0,
        smoothestFifoResetCount: UInt64 = 0,
        smoothestDepthDrops: UInt64 = 0,
        smoothestAgeDrops: UInt64 = 0,
        smoothestDropsUnder100ms: UInt64 = 0,
        smoothestDroppedFrameAgeMaxMs: Double = 0,
        lateFrameDrops: UInt64 = 0,
        displayLayerNotReadyCount: UInt64,
        pendingFrameNotReadyDisplayTickCount: UInt64 = 0,
        repeatedFrameCount: UInt64 = 0,
        displayTickNoFrameCount: UInt64 = 0,
        missedVSyncCount: UInt64 = 0,
        displayTickIntervalP95Ms: Double = 0,
        displayTickIntervalP99Ms: Double = 0,
        playoutDelayFrames: Int = 0,
        presentationStallCount: UInt64 = 0,
        worstPresentationGapMs: Double = 0,
        frameIntervalP95Ms: Double = 0,
        frameIntervalP99Ms: Double = 0,
        decodeHealthy: Bool
    ) {
        updateSnapshot(for: streamID) { snapshot in
            snapshot.decodedFPS = decodedFPS
            snapshot.receivedFPS = receivedFPS
            snapshot.clientReceivedWorstGapMs = max(0, receivedWorstGapMs)
            snapshot.clientReceivedFrameIntervalP95Ms = max(0, receivedFrameIntervalP95Ms)
            snapshot.clientReceivedFrameIntervalP99Ms = max(0, receivedFrameIntervalP99Ms)
            snapshot.clientReceiverIngressJitterP95Ms = max(0, receiverIngressJitterP95Ms)
            snapshot.clientReceiverIngressJitterP99Ms = max(0, receiverIngressJitterP99Ms)
            snapshot.clientDisplayTickFPS = max(0, displayTickFPS)
            snapshot.clientSubmitAttemptFPS = max(0, submitAttemptFPS)
            snapshot.clientLayerAcceptedFPS = max(0, layerAcceptedFPS)
            snapshot.clientPresentedFPS = max(0, presentedFPS)
            snapshot.submittedFPS = submittedFPS
            snapshot.uniqueSubmittedFPS = uniqueSubmittedFPS
            snapshot.pendingFrameCount = max(0, pendingFrameCount)
            snapshot.clientPendingFrameAgeMs = max(0, pendingFrameAgeMs)
            snapshot.clientSmoothestDisplayDebtMs = max(0, smoothestDisplayDebtMs)
            snapshot.clientSmoothestDisplayDebtCapMs = max(0, smoothestDisplayDebtCapMs)
            snapshot.clientSmoothestTargetDelayMs = max(0, smoothestTargetDelayMs)
            snapshot.clientSmoothestUnderflowCount = displayTickNoFrameCount
            snapshot.clientOverwrittenPendingFrames = overwrittenPendingFrames
            snapshot.clientSmoothestQueueDrops = smoothestQueueDrops
            snapshot.clientSmoothestDisplayDebtDrops = smoothestDisplayDebtDrops
            snapshot.clientSmoothestFifoResetCount = smoothestFifoResetCount
            snapshot.clientSmoothestDepthDrops = smoothestDepthDrops
            snapshot.clientSmoothestAgeDrops = smoothestAgeDrops
            snapshot.clientSmoothestDropsUnder100ms = smoothestDropsUnder100ms
            snapshot.clientSmoothestDroppedFrameAgeMaxMs = max(0, smoothestDroppedFrameAgeMaxMs)
            snapshot.clientLateFrameDrops = lateFrameDrops
            snapshot.clientDisplayLayerNotReadyCount = displayLayerNotReadyCount
            snapshot.clientPendingFrameNotReadyDisplayTickCount = pendingFrameNotReadyDisplayTickCount
            snapshot.clientRepeatedFrameCount = repeatedFrameCount
            snapshot.clientMissedVSyncCount = missedVSyncCount
            snapshot.clientDisplayTickIntervalP95Ms = max(0, displayTickIntervalP95Ms)
            snapshot.clientDisplayTickIntervalP99Ms = max(0, displayTickIntervalP99Ms)
            snapshot.clientPlayoutDelayFrames = max(0, playoutDelayFrames)
            snapshot.clientPresentationStallCount = presentationStallCount
            snapshot.clientWorstPresentationGapMs = max(0, worstPresentationGapMs)
            snapshot.clientFrameIntervalP95Ms = max(0, frameIntervalP95Ms)
            snapshot.clientFrameIntervalP99Ms = max(0, frameIntervalP99Ms)
            snapshot.decodeHealthy = decodeHealthy
            snapshot.clientDroppedFrames = droppedFrames
            snapshot.clientDecodeBacklogFrameCount = max(0, decodeBacklogFrames)
            snapshot.clientReassemblerPendingFrameCount = max(0, reassemblerPendingFrameCount)
            snapshot.clientReassemblerPendingKeyframeCount = max(0, reassemblerPendingKeyframeCount)
            snapshot.clientReassemblerPendingBytes = max(0, reassemblerPendingBytes)
            snapshot.clientFrameBufferPoolRetainedBytes = max(0, frameBufferPoolRetainedBytes)
            snapshot.clientReassemblerBudgetEvictions = reassemblerBudgetEvictions
            snapshot.clientReassemblerIncompleteFrameTimeouts = reassemblerIncompleteFrameTimeouts
            snapshot.clientReassemblerIncompleteFrameNoProgressTimeouts = reassemblerIncompleteFrameNoProgressTimeouts
            snapshot.clientReassemblerIncompleteFrameLifetimeTimeouts = reassemblerIncompleteFrameLifetimeTimeouts
            snapshot.clientReassemblerMissingFragmentTimeouts = reassemblerMissingFragmentTimeouts
            snapshot.clientReassemblerForwardGapTimeouts = reassemblerForwardGapTimeouts
            snapshot.clientFrameCompletionLatencyP50Ms = max(0, frameCompletionLatencyP50Ms)
            snapshot.clientFrameCompletionLatencyP95Ms = max(0, frameCompletionLatencyP95Ms)
            snapshot.clientFrameCompletionLatencyMaxMs = max(0, frameCompletionLatencyMaxMs)
            snapshot.clientKeyframeCompletionLatencyP50Ms = max(0, keyframeCompletionLatencyP50Ms)
            snapshot.clientKeyframeCompletionLatencyP95Ms = max(0, keyframeCompletionLatencyP95Ms)
            snapshot.clientKeyframeCompletionLatencyMaxMs = max(0, keyframeCompletionLatencyMaxMs)
            snapshot.clientPFrameCompletionLatencyP50Ms = max(0, pFrameCompletionLatencyP50Ms)
            snapshot.clientPFrameCompletionLatencyP95Ms = max(0, pFrameCompletionLatencyP95Ms)
            snapshot.clientPFrameCompletionLatencyMaxMs = max(0, pFrameCompletionLatencyMaxMs)
            snapshot.clientLatePFrameCompletionCount = latePFrameCompletionCount
            snapshot.clientReassemblerFECRecoveredFragmentCount = reassemblerFECRecoveredFragmentCount
        }
    }

    /// Returns the latest metrics snapshot for a stream.
    public func snapshot(for streamID: StreamID) -> MirageDiagnostics.MirageClientMetricsSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return metricsByStream[streamID]
    }

    /// Removes metrics for one stream.
    public func clear(streamID: StreamID) {
        lock.lock()
        defer { lock.unlock() }
        metricsByStream.removeValue(forKey: streamID)
    }

    /// Removes metrics for every stream.
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        metricsByStream.removeAll()
    }

    /// Mutates one stream snapshot while holding the store lock.
    func updateSnapshot(
        for streamID: StreamID,
        _ update: (inout MirageDiagnostics.MirageClientMetricsSnapshot) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = metricsByStream[streamID] ?? MirageDiagnostics.MirageClientMetricsSnapshot()
        update(&snapshot)
        metricsByStream[streamID] = snapshot
    }
}
