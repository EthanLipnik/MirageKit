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
    public var hostCurrentBitrate: Int?
    public var hostRequestedTargetBitrate: Int?
    public var hostStartupBitrate: Int?
    public var hostTemporaryDegradationMode: MirageTemporaryDegradationMode?
    public var hostTemporaryDegradationColorDepth: MirageStreamColorDepth?
    public var hostTimeBelowTargetBitrateMs: Int?
    public var hostCaptureAdmissionDrops: UInt64?
    public var hostFrameBudgetMs: Double?
    public var hostAverageEncodeMs: Double?
    public var hostUsingHardwareEncoder: Bool?
    public var hostEncoderGPURegistryID: UInt64?
    public var hostEncodedWidth: Int?
    public var hostEncodedHeight: Int?
    public var hostCapturePixelFormat: String?
    public var hostCaptureColorPrimaries: String?
    public var hostEncoderPixelFormat: String?
    public var hostEncoderChromaSampling: String?
    public var hostEncoderProfile: String?
    public var hostEncoderColorPrimaries: String?
    public var hostEncoderTransferFunction: String?
    public var hostEncoderYCbCrMatrix: String?
    public var hostDisplayP3CoverageStatus: MirageDisplayP3CoverageStatus?
    public var hostTenBitDisplayP3Validated: Bool?
    public var hostUltra444Validated: Bool?
    public var clientDecoderOutputPixelFormat: String?
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
        hostCurrentBitrate: Int? = nil,
        hostRequestedTargetBitrate: Int? = nil,
        hostStartupBitrate: Int? = nil,
        hostTemporaryDegradationMode: MirageTemporaryDegradationMode? = nil,
        hostTemporaryDegradationColorDepth: MirageStreamColorDepth? = nil,
        hostTimeBelowTargetBitrateMs: Int? = nil,
        hostCaptureAdmissionDrops: UInt64? = nil,
        hostFrameBudgetMs: Double? = nil,
        hostAverageEncodeMs: Double? = nil,
        hostUsingHardwareEncoder: Bool? = nil,
        hostEncoderGPURegistryID: UInt64? = nil,
        hostEncodedWidth: Int? = nil,
        hostEncodedHeight: Int? = nil,
        hostCapturePixelFormat: String? = nil,
        hostCaptureColorPrimaries: String? = nil,
        hostEncoderPixelFormat: String? = nil,
        hostEncoderChromaSampling: String? = nil,
        hostEncoderProfile: String? = nil,
        hostEncoderColorPrimaries: String? = nil,
        hostEncoderTransferFunction: String? = nil,
        hostEncoderYCbCrMatrix: String? = nil,
        hostDisplayP3CoverageStatus: MirageDisplayP3CoverageStatus? = nil,
        hostTenBitDisplayP3Validated: Bool? = nil,
        hostUltra444Validated: Bool? = nil,
        clientDecoderOutputPixelFormat: String? = nil,
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
        self.hostCurrentBitrate = hostCurrentBitrate
        self.hostRequestedTargetBitrate = hostRequestedTargetBitrate
        self.hostStartupBitrate = hostStartupBitrate
        self.hostTemporaryDegradationMode = hostTemporaryDegradationMode
        self.hostTemporaryDegradationColorDepth = hostTemporaryDegradationColorDepth
        self.hostTimeBelowTargetBitrateMs = hostTimeBelowTargetBitrateMs
        self.hostCaptureAdmissionDrops = hostCaptureAdmissionDrops
        self.hostFrameBudgetMs = hostFrameBudgetMs
        self.hostAverageEncodeMs = hostAverageEncodeMs
        self.hostUsingHardwareEncoder = hostUsingHardwareEncoder
        self.hostEncoderGPURegistryID = hostEncoderGPURegistryID
        self.hostEncodedWidth = hostEncodedWidth
        self.hostEncodedHeight = hostEncodedHeight
        self.hostCapturePixelFormat = hostCapturePixelFormat
        self.hostCaptureColorPrimaries = hostCaptureColorPrimaries
        self.hostEncoderPixelFormat = hostEncoderPixelFormat
        self.hostEncoderChromaSampling = hostEncoderChromaSampling
        self.hostEncoderProfile = hostEncoderProfile
        self.hostEncoderColorPrimaries = hostEncoderColorPrimaries
        self.hostEncoderTransferFunction = hostEncoderTransferFunction
        self.hostEncoderYCbCrMatrix = hostEncoderYCbCrMatrix
        self.hostDisplayP3CoverageStatus = hostDisplayP3CoverageStatus
        self.hostTenBitDisplayP3Validated = hostTenBitDisplayP3Validated
        self.hostUltra444Validated = hostUltra444Validated
        self.clientDecoderOutputPixelFormat = clientDecoderOutputPixelFormat
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
        currentBitrate: Int? = nil,
        requestedTargetBitrate: Int? = nil,
        startupBitrate: Int? = nil,
        temporaryDegradationMode: MirageTemporaryDegradationMode? = nil,
        temporaryDegradationColorDepth: MirageStreamColorDepth? = nil,
        timeBelowTargetBitrateMs: Int? = nil,
        captureAdmissionDrops: UInt64? = nil,
        frameBudgetMs: Double? = nil,
        averageEncodeMs: Double?,
        usingHardwareEncoder: Bool?,
        encoderGPURegistryID: UInt64?,
        encodedWidth: Int?,
        encodedHeight: Int?,
        capturePixelFormat: String?,
        captureColorPrimaries: String?,
        encoderPixelFormat: String?,
        encoderChromaSampling: String?,
        encoderProfile: String?,
        encoderColorPrimaries: String?,
        encoderTransferFunction: String?,
        encoderYCbCrMatrix: String?,
        displayP3CoverageStatus: MirageDisplayP3CoverageStatus?,
        tenBitDisplayP3Validated: Bool?,
        ultra444Validated: Bool?
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.hostEncodedFPS = encodedFPS
        snapshot.hostIdleFPS = idleEncodedFPS
        snapshot.hostDroppedFrames = droppedFrames
        snapshot.hostActiveQuality = activeQuality
        snapshot.hostTargetFrameRate = targetFrameRate
        snapshot.hostCurrentBitrate = currentBitrate
        snapshot.hostRequestedTargetBitrate = requestedTargetBitrate
        snapshot.hostStartupBitrate = startupBitrate
        snapshot.hostTemporaryDegradationMode = temporaryDegradationMode
        snapshot.hostTemporaryDegradationColorDepth = temporaryDegradationColorDepth
        snapshot.hostTimeBelowTargetBitrateMs = timeBelowTargetBitrateMs
        snapshot.hostCaptureAdmissionDrops = captureAdmissionDrops
        snapshot.hostFrameBudgetMs = frameBudgetMs
        snapshot.hostAverageEncodeMs = averageEncodeMs
        snapshot.hostUsingHardwareEncoder = usingHardwareEncoder
        snapshot.hostEncoderGPURegistryID = encoderGPURegistryID
        snapshot.hostEncodedWidth = encodedWidth
        snapshot.hostEncodedHeight = encodedHeight
        snapshot.hostCapturePixelFormat = capturePixelFormat
        snapshot.hostCaptureColorPrimaries = captureColorPrimaries
        snapshot.hostEncoderPixelFormat = encoderPixelFormat
        snapshot.hostEncoderChromaSampling = encoderChromaSampling
        snapshot.hostEncoderProfile = encoderProfile
        snapshot.hostEncoderColorPrimaries = encoderColorPrimaries
        snapshot.hostEncoderTransferFunction = encoderTransferFunction
        snapshot.hostEncoderYCbCrMatrix = encoderYCbCrMatrix
        snapshot.hostDisplayP3CoverageStatus = displayP3CoverageStatus
        snapshot.hostTenBitDisplayP3Validated = tenBitDisplayP3Validated
        snapshot.hostUltra444Validated = ultra444Validated
        snapshot.hasHostMetrics = true
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    public func updateClientDecoderTelemetry(
        streamID: StreamID,
        outputPixelFormat: String?
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.clientDecoderOutputPixelFormat = outputPixelFormat
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
