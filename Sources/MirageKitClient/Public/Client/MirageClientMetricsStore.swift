//
//  MirageClientMetricsStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation
import MirageKit

/// Thread-safe metrics store for client stream telemetry.
public struct MirageClientMetricsSnapshot: Sendable, Equatable {
    public var decodedFPS: Double
    public var receivedFPS: Double
    public var presentedFPS: Double
    public var uniquePresentedFPS: Double
    public var renderBufferDepth: Int
    public var decodeHealthy: Bool
    public var clientDroppedFrames: UInt64
    public var hostEncodedFPS: Double
    public var hostIdleFPS: Double
    public var hostDroppedFrames: UInt64
    public var hostActiveQuality: Double
    public var hostTargetFrameRate: Int
    public var hasHostMetrics: Bool

    public init(
        decodedFPS: Double = 0,
        receivedFPS: Double = 0,
        presentedFPS: Double = 0,
        uniquePresentedFPS: Double = 0,
        renderBufferDepth: Int = 0,
        decodeHealthy: Bool = true,
        clientDroppedFrames: UInt64 = 0,
        hostEncodedFPS: Double = 0,
        hostIdleFPS: Double = 0,
        hostDroppedFrames: UInt64 = 0,
        hostActiveQuality: Double = 0,
        hostTargetFrameRate: Int = 0,
        hasHostMetrics: Bool = false
    ) {
        self.decodedFPS = decodedFPS
        self.receivedFPS = receivedFPS
        self.presentedFPS = presentedFPS
        self.uniquePresentedFPS = uniquePresentedFPS
        self.renderBufferDepth = renderBufferDepth
        self.decodeHealthy = decodeHealthy
        self.clientDroppedFrames = clientDroppedFrames
        self.hostEncodedFPS = hostEncodedFPS
        self.hostIdleFPS = hostIdleFPS
        self.hostDroppedFrames = hostDroppedFrames
        self.hostActiveQuality = hostActiveQuality
        self.hostTargetFrameRate = hostTargetFrameRate
        self.hasHostMetrics = hasHostMetrics
    }
}

public final class MirageClientMetricsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var metricsByStream: [StreamID: MirageClientMetricsSnapshot] = [:]

    public init() {}

    public func updateClientMetrics(
        streamID: StreamID,
        decodedFPS: Double,
        receivedFPS: Double,
        droppedFrames: UInt64,
        presentedFPS: Double,
        uniquePresentedFPS: Double,
        renderBufferDepth: Int,
        decodeHealthy: Bool
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.decodedFPS = decodedFPS
        snapshot.receivedFPS = receivedFPS
        snapshot.presentedFPS = presentedFPS
        snapshot.uniquePresentedFPS = uniquePresentedFPS
        snapshot.renderBufferDepth = max(0, renderBufferDepth)
        snapshot.decodeHealthy = decodeHealthy
        snapshot.clientDroppedFrames = droppedFrames
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    public func updateHostMetrics(
        streamID: StreamID,
        encodedFPS: Double,
        idleEncodedFPS: Double,
        droppedFrames: UInt64,
        activeQuality: Double,
        targetFrameRate: Int
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.hostEncodedFPS = encodedFPS
        snapshot.hostIdleFPS = idleEncodedFPS
        snapshot.hostDroppedFrames = droppedFrames
        snapshot.hostActiveQuality = activeQuality
        snapshot.hostTargetFrameRate = targetFrameRate
        snapshot.hasHostMetrics = true
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    public func snapshot(for streamID: StreamID) -> MirageClientMetricsSnapshot? {
        lock.lock()
        let result = metricsByStream[streamID]
        lock.unlock()
        return result
    }

    public func clear(streamID: StreamID) {
        lock.lock()
        metricsByStream.removeValue(forKey: streamID)
        lock.unlock()
    }

    public func clearAll() {
        lock.lock()
        metricsByStream.removeAll()
        lock.unlock()
    }
}
