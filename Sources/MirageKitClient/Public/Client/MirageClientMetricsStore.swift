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
    public var submittedFPS: Double
    public var uniqueSubmittedFPS: Double
    public var pendingFrameCount: Int
    public var decodeHealthy: Bool
    public var clientDroppedFrames: UInt64
    public var hostEncodedFPS: Double
    public var hostIdleFPS: Double
    public var hostDroppedFrames: UInt64
    public var hostActiveQuality: Double
    public var hostTargetFrameRate: Int
    public var hostEnteredBitrate: Int?
    public var hostCurrentBitrate: Int?
    public var hostRequestedTargetBitrate: Int?
    public var hostBitrateAdaptationCeiling: Int?
    public var hostStartupBitrate: Int?
    public var hostCaptureAdmissionDrops: UInt64?
    public var hostFrameBudgetMs: Double?
    public var hostAverageEncodeMs: Double?
    public var hostCaptureIngressFPS: Double?
    public var hostCaptureFPS: Double?
    public var hostEncodeAttemptFPS: Double?
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
    public var clientUsingHardwareDecoder: Bool?
    package var hostCaptureIngressAverageMs: Double? = nil
    package var hostCaptureIngressMaxMs: Double? = nil
    package var hostPreEncodeWaitAverageMs: Double? = nil
    package var hostPreEncodeWaitMaxMs: Double? = nil
    package var hostCaptureCallbackAverageMs: Double? = nil
    package var hostCaptureCallbackMaxMs: Double? = nil
    package var hostCaptureCopyAverageMs: Double? = nil
    package var hostCaptureCopyMaxMs: Double? = nil
    package var hostCaptureCopyPoolDrops: UInt64? = nil
    package var hostCaptureCopyInFlightDrops: UInt64? = nil
    package var hostSendQueueBytes: Int? = nil
    package var hostSendStartDelayAverageMs: Double? = nil
    package var hostSendStartDelayMaxMs: Double? = nil
    package var hostSendCompletionAverageMs: Double? = nil
    package var hostSendCompletionMaxMs: Double? = nil
    package var hostPacketPacerAverageSleepMs: Double? = nil
    package var hostPacketPacerMaxSleepMs: Int? = nil
    package var hostStalePacketDrops: UInt64? = nil
    package var hostGenerationAbortDrops: UInt64? = nil
    package var hostNonKeyframeHoldDrops: UInt64? = nil
    public var hasHostMetrics: Bool

    public init(
        decodedFPS: Double = 0,
        receivedFPS: Double = 0,
        submittedFPS: Double = 0,
        uniqueSubmittedFPS: Double = 0,
        pendingFrameCount: Int = 0,
        decodeHealthy: Bool = true,
        clientDroppedFrames: UInt64 = 0,
        hostEncodedFPS: Double = 0,
        hostIdleFPS: Double = 0,
        hostDroppedFrames: UInt64 = 0,
        hostActiveQuality: Double = 0,
        hostTargetFrameRate: Int = 0,
        hostEnteredBitrate: Int? = nil,
        hostCurrentBitrate: Int? = nil,
        hostRequestedTargetBitrate: Int? = nil,
        hostBitrateAdaptationCeiling: Int? = nil,
        hostStartupBitrate: Int? = nil,
        hostCaptureAdmissionDrops: UInt64? = nil,
        hostFrameBudgetMs: Double? = nil,
        hostAverageEncodeMs: Double? = nil,
        hostCaptureIngressFPS: Double? = nil,
        hostCaptureFPS: Double? = nil,
        hostEncodeAttemptFPS: Double? = nil,
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
        clientUsingHardwareDecoder: Bool? = nil,
        hasHostMetrics: Bool = false
    ) {
        self.decodedFPS = decodedFPS
        self.receivedFPS = receivedFPS
        self.submittedFPS = submittedFPS
        self.uniqueSubmittedFPS = uniqueSubmittedFPS
        self.pendingFrameCount = pendingFrameCount
        self.decodeHealthy = decodeHealthy
        self.clientDroppedFrames = clientDroppedFrames
        self.hostEncodedFPS = hostEncodedFPS
        self.hostIdleFPS = hostIdleFPS
        self.hostDroppedFrames = hostDroppedFrames
        self.hostActiveQuality = hostActiveQuality
        self.hostTargetFrameRate = hostTargetFrameRate
        self.hostEnteredBitrate = hostEnteredBitrate
        self.hostCurrentBitrate = hostCurrentBitrate
        self.hostRequestedTargetBitrate = hostRequestedTargetBitrate
        self.hostBitrateAdaptationCeiling = hostBitrateAdaptationCeiling
        self.hostStartupBitrate = hostStartupBitrate
        self.hostCaptureAdmissionDrops = hostCaptureAdmissionDrops
        self.hostFrameBudgetMs = hostFrameBudgetMs
        self.hostAverageEncodeMs = hostAverageEncodeMs
        self.hostCaptureIngressFPS = hostCaptureIngressFPS
        self.hostCaptureFPS = hostCaptureFPS
        self.hostEncodeAttemptFPS = hostEncodeAttemptFPS
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
        self.clientUsingHardwareDecoder = clientUsingHardwareDecoder
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
        submittedFPS: Double,
        uniqueSubmittedFPS: Double,
        pendingFrameCount: Int,
        decodeHealthy: Bool
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.decodedFPS = decodedFPS
        snapshot.receivedFPS = receivedFPS
        snapshot.submittedFPS = submittedFPS
        snapshot.uniqueSubmittedFPS = uniqueSubmittedFPS
        snapshot.pendingFrameCount = max(0, pendingFrameCount)
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
        enteredBitrate: Int? = nil,
        currentBitrate: Int? = nil,
        requestedTargetBitrate: Int? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        startupBitrate: Int? = nil,
        captureAdmissionDrops: UInt64? = nil,
        frameBudgetMs: Double? = nil,
        averageEncodeMs: Double?,
        captureIngressFPS: Double? = nil,
        captureFPS: Double? = nil,
        encodeAttemptFPS: Double? = nil,
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
        snapshot.hostEnteredBitrate = enteredBitrate
        snapshot.hostCurrentBitrate = currentBitrate
        snapshot.hostRequestedTargetBitrate = requestedTargetBitrate
        snapshot.hostBitrateAdaptationCeiling = bitrateAdaptationCeiling
        snapshot.hostStartupBitrate = startupBitrate
        snapshot.hostCaptureAdmissionDrops = captureAdmissionDrops
        snapshot.hostFrameBudgetMs = frameBudgetMs
        snapshot.hostAverageEncodeMs = averageEncodeMs
        snapshot.hostCaptureIngressFPS = captureIngressFPS
        snapshot.hostCaptureFPS = captureFPS
        snapshot.hostEncodeAttemptFPS = encodeAttemptFPS
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

    func updateHostPipelineMetrics(
        streamID: StreamID,
        captureIngressAverageMs: Double?,
        captureIngressMaxMs: Double?,
        preEncodeWaitAverageMs: Double?,
        preEncodeWaitMaxMs: Double?,
        captureCallbackAverageMs: Double?,
        captureCallbackMaxMs: Double?,
        captureCopyAverageMs: Double?,
        captureCopyMaxMs: Double?,
        captureCopyPoolDrops: UInt64?,
        captureCopyInFlightDrops: UInt64?,
        sendQueueBytes: Int?,
        sendStartDelayAverageMs: Double?,
        sendStartDelayMaxMs: Double?,
        sendCompletionAverageMs: Double?,
        sendCompletionMaxMs: Double?,
        packetPacerAverageSleepMs: Double?,
        packetPacerMaxSleepMs: Int?,
        stalePacketDrops: UInt64?,
        generationAbortDrops: UInt64?,
        nonKeyframeHoldDrops: UInt64?
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.hostCaptureIngressAverageMs = captureIngressAverageMs
        snapshot.hostCaptureIngressMaxMs = captureIngressMaxMs
        snapshot.hostPreEncodeWaitAverageMs = preEncodeWaitAverageMs
        snapshot.hostPreEncodeWaitMaxMs = preEncodeWaitMaxMs
        snapshot.hostCaptureCallbackAverageMs = captureCallbackAverageMs
        snapshot.hostCaptureCallbackMaxMs = captureCallbackMaxMs
        snapshot.hostCaptureCopyAverageMs = captureCopyAverageMs
        snapshot.hostCaptureCopyMaxMs = captureCopyMaxMs
        snapshot.hostCaptureCopyPoolDrops = captureCopyPoolDrops
        snapshot.hostCaptureCopyInFlightDrops = captureCopyInFlightDrops
        snapshot.hostSendQueueBytes = sendQueueBytes
        snapshot.hostSendStartDelayAverageMs = sendStartDelayAverageMs
        snapshot.hostSendStartDelayMaxMs = sendStartDelayMaxMs
        snapshot.hostSendCompletionAverageMs = sendCompletionAverageMs
        snapshot.hostSendCompletionMaxMs = sendCompletionMaxMs
        snapshot.hostPacketPacerAverageSleepMs = packetPacerAverageSleepMs
        snapshot.hostPacketPacerMaxSleepMs = packetPacerMaxSleepMs
        snapshot.hostStalePacketDrops = stalePacketDrops
        snapshot.hostGenerationAbortDrops = generationAbortDrops
        snapshot.hostNonKeyframeHoldDrops = nonKeyframeHoldDrops
        metricsByStream[streamID] = snapshot
        lock.unlock()
    }

    public func updateClientDecoderTelemetry(
        streamID: StreamID,
        outputPixelFormat: String?,
        usingHardwareDecoder: Bool?
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.clientDecoderOutputPixelFormat = outputPixelFormat
        snapshot.clientUsingHardwareDecoder = usingHardwareDecoder
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
