//
//  MirageClientMetricsStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation
import MirageKit

/// Thread-safe per-stream telemetry store used by client UI, diagnostics, and recovery policy.
public final class MirageClientMetricsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var metricsByStream: [StreamID: MirageClientMetricsSnapshot] = [:]

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
        droppedFrames: UInt64,
        reassemblerPendingFrameCount: Int = 0,
        reassemblerPendingKeyframeCount: Int = 0,
        reassemblerPendingBytes: Int = 0,
        frameBufferPoolRetainedBytes: Int = 0,
        reassemblerBudgetEvictions: UInt64 = 0,
        displayTickFPS: Double = 0,
        submitAttemptFPS: Double = 0,
        layerAcceptedFPS: Double = 0,
        presentedFPS: Double = 0,
        submittedFPS: Double,
        uniqueSubmittedFPS: Double,
        pendingFrameCount: Int,
        pendingFrameAgeMs: Double,
        overwrittenPendingFrames: UInt64,
        smoothestQueueDrops: UInt64 = 0,
        lateFrameDrops: UInt64 = 0,
        displayLayerNotReadyCount: UInt64,
        repeatedFrameCount: UInt64 = 0,
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
            snapshot.clientDisplayTickFPS = max(0, displayTickFPS)
            snapshot.clientSubmitAttemptFPS = max(0, submitAttemptFPS)
            snapshot.clientLayerAcceptedFPS = max(0, layerAcceptedFPS)
            snapshot.clientPresentedFPS = max(0, presentedFPS)
            snapshot.submittedFPS = submittedFPS
            snapshot.uniqueSubmittedFPS = uniqueSubmittedFPS
            snapshot.pendingFrameCount = max(0, pendingFrameCount)
            snapshot.clientPendingFrameAgeMs = max(0, pendingFrameAgeMs)
            snapshot.clientOverwrittenPendingFrames = overwrittenPendingFrames
            snapshot.clientSmoothestQueueDrops = smoothestQueueDrops
            snapshot.clientLateFrameDrops = lateFrameDrops
            snapshot.clientDisplayLayerNotReadyCount = displayLayerNotReadyCount
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
            snapshot.clientReassemblerPendingFrameCount = max(0, reassemblerPendingFrameCount)
            snapshot.clientReassemblerPendingKeyframeCount = max(0, reassemblerPendingKeyframeCount)
            snapshot.clientReassemblerPendingBytes = max(0, reassemblerPendingBytes)
            snapshot.clientFrameBufferPoolRetainedBytes = max(0, frameBufferPoolRetainedBytes)
            snapshot.clientReassemblerBudgetEvictions = reassemblerBudgetEvictions
        }
    }

    /// Returns the latest metrics snapshot for a stream.
    public func snapshot(for streamID: StreamID) -> MirageClientMetricsSnapshot? {
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
        _ update: (inout MirageClientMetricsSnapshot) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        update(&snapshot)
        metricsByStream[streamID] = snapshot
    }
}
