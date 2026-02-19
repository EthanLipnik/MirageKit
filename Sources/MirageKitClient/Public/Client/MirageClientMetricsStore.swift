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
    public var hostCapturePixelFormat: String?
    public var hostCaptureColorPrimaries: String?
    public var hostEncoderPixelFormat: String?
    public var hostEncoderProfile: String?
    public var hostEncoderColorPrimaries: String?
    public var hostEncoderTransferFunction: String?
    public var hostEncoderYCbCrMatrix: String?
    public var hostTenBitDisplayP3Validated: Bool?
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
        hostCapturePixelFormat: String? = nil,
        hostCaptureColorPrimaries: String? = nil,
        hostEncoderPixelFormat: String? = nil,
        hostEncoderProfile: String? = nil,
        hostEncoderColorPrimaries: String? = nil,
        hostEncoderTransferFunction: String? = nil,
        hostEncoderYCbCrMatrix: String? = nil,
        hostTenBitDisplayP3Validated: Bool? = nil,
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
        self.hostCapturePixelFormat = hostCapturePixelFormat
        self.hostCaptureColorPrimaries = hostCaptureColorPrimaries
        self.hostEncoderPixelFormat = hostEncoderPixelFormat
        self.hostEncoderProfile = hostEncoderProfile
        self.hostEncoderColorPrimaries = hostEncoderColorPrimaries
        self.hostEncoderTransferFunction = hostEncoderTransferFunction
        self.hostEncoderYCbCrMatrix = hostEncoderYCbCrMatrix
        self.hostTenBitDisplayP3Validated = hostTenBitDisplayP3Validated
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
        targetFrameRate: Int,
        capturePixelFormat: String?,
        captureColorPrimaries: String?,
        encoderPixelFormat: String?,
        encoderProfile: String?,
        encoderColorPrimaries: String?,
        encoderTransferFunction: String?,
        encoderYCbCrMatrix: String?,
        tenBitDisplayP3Validated: Bool?
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.hostEncodedFPS = encodedFPS
        snapshot.hostIdleFPS = idleEncodedFPS
        snapshot.hostDroppedFrames = droppedFrames
        snapshot.hostActiveQuality = activeQuality
        snapshot.hostTargetFrameRate = targetFrameRate
        snapshot.hostCapturePixelFormat = capturePixelFormat
        snapshot.hostCaptureColorPrimaries = captureColorPrimaries
        snapshot.hostEncoderPixelFormat = encoderPixelFormat
        snapshot.hostEncoderProfile = encoderProfile
        snapshot.hostEncoderColorPrimaries = encoderColorPrimaries
        snapshot.hostEncoderTransferFunction = encoderTransferFunction
        snapshot.hostEncoderYCbCrMatrix = encoderYCbCrMatrix
        snapshot.hostTenBitDisplayP3Validated = tenBitDisplayP3Validated
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
