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
    public var clientReceivedWorstGapMs: Double
    public var clientReceivedFrameIntervalP95Ms: Double
    public var clientReceivedFrameIntervalP99Ms: Double
    public var clientSubmitAttemptFPS: Double
    public var clientLayerAcceptedFPS: Double
    public var clientPresentedFPS: Double
    public var submittedFPS: Double
    public var uniqueSubmittedFPS: Double
    public var pendingFrameCount: Int
    public var clientPendingFrameAgeMs: Double
    public var clientOverwrittenPendingFrames: UInt64
    public var clientDisplayLayerNotReadyCount: UInt64
    public var clientPresentationStallCount: UInt64
    public var clientWorstPresentationGapMs: Double
    public var clientFrameIntervalP95Ms: Double
    public var clientFrameIntervalP99Ms: Double
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
    public var hostCaptureWallClockGapWorstMs: Double? = nil
    public var hostCaptureWallClockGapP95Ms: Double? = nil
    public var hostCaptureWallClockGapP99Ms: Double? = nil
    public var hostCaptureDisplayTimeGapWorstMs: Double? = nil
    public var hostCaptureDisplayTimeGapP95Ms: Double? = nil
    public var hostCaptureDisplayTimeGapP99Ms: Double? = nil
    public var hostCaptureDeliveredFrameGapWorstMs: Double? = nil
    public var hostCaptureDeliveredFrameGapP95Ms: Double? = nil
    public var hostCaptureDeliveredFrameGapP99Ms: Double? = nil
    public var hostCaptureCallbackP95Ms: Double? = nil
    public var hostCaptureCallbackP99Ms: Double? = nil
    public var hostCaptureLongFrameGapCount: UInt64? = nil
    public var hostCaptureDisplayTimeDriftCount: UInt64? = nil
    public var hostCaptureVirtualDisplayTimingSuspect: Bool? = nil
    public var hostCaptureUsesDisplayRefreshCadence: Bool? = nil
    public var hostCaptureUsesNativeRefreshMinimumFrameInterval: Bool? = nil
    public var hostCaptureMinimumFrameIntervalRate: Int? = nil
    public var hostCaptureDisplayRefreshRate: Int? = nil
    public var hostVirtualDisplayID: UInt32? = nil
    public var hostVirtualDisplayRefreshRate: Double? = nil
    public var hostVirtualDisplayScaleFactor: Double? = nil
    package var hostCaptureStatusCompleteCount: UInt64? = nil
    package var hostCaptureStatusIdleCount: UInt64? = nil
    package var hostCaptureStatusBlankCount: UInt64? = nil
    package var hostCaptureStatusSuspendedCount: UInt64? = nil
    package var hostCaptureStatusStartedCount: UInt64? = nil
    package var hostCaptureStatusStoppedCount: UInt64? = nil
    package var hostCaptureStatusUnknownCount: UInt64? = nil
    package var hostCaptureCadenceDropCount: UInt64? = nil
    package var hostCaptureCadenceSampleOverwriteCount: UInt64? = nil
    package var hostSendQueueBytes: Int? = nil
    package var hostSendStartDelayAverageMs: Double? = nil
    package var hostSendStartDelayMaxMs: Double? = nil
    package var hostSendCompletionAverageMs: Double? = nil
    package var hostSendCompletionMaxMs: Double? = nil
    package var hostPacketPacerAverageSleepMs: Double? = nil
    package var hostPacketPacerTotalSleepMs: Int? = nil
    package var hostPacketPacerMaxSleepMs: Int? = nil
    package var hostPacketPacerFrameMaxSleepMs: Int? = nil
    package var hostStalePacketDrops: UInt64? = nil
    package var hostGenerationAbortDrops: UInt64? = nil
    package var hostNonKeyframeHoldDrops: UInt64? = nil
    public var hasHostMetrics: Bool

    public var hostTransportSendQueueBytes: Int? { hostSendQueueBytes }
    public var hostTransportSendStartDelayAverageMs: Double? { hostSendStartDelayAverageMs }
    public var hostTransportSendCompletionAverageMs: Double? { hostSendCompletionAverageMs }
    public var hostTransportPacketPacerAverageSleepMs: Double? { hostPacketPacerAverageSleepMs }
    public var hostTransportPacketPacerTotalSleepMs: Int? { hostPacketPacerTotalSleepMs }
    public var hostTransportPacketPacerMaxSleepMs: Int? { hostPacketPacerMaxSleepMs }
    public var hostTransportPacketPacerFrameMaxSleepMs: Int? { hostPacketPacerFrameMaxSleepMs }
    public var hostTransportStalePacketDrops: UInt64? { hostStalePacketDrops }
    public var hostTransportGenerationAbortDrops: UInt64? { hostGenerationAbortDrops }
    public var hostTransportNonKeyframeHoldDrops: UInt64? { hostNonKeyframeHoldDrops }

    public init(
        decodedFPS: Double = 0,
        receivedFPS: Double = 0,
        clientReceivedWorstGapMs: Double = 0,
        clientReceivedFrameIntervalP95Ms: Double = 0,
        clientReceivedFrameIntervalP99Ms: Double = 0,
        clientSubmitAttemptFPS: Double = 0,
        clientLayerAcceptedFPS: Double = 0,
        clientPresentedFPS: Double = 0,
        submittedFPS: Double = 0,
        uniqueSubmittedFPS: Double = 0,
        pendingFrameCount: Int = 0,
        clientPendingFrameAgeMs: Double = 0,
        clientOverwrittenPendingFrames: UInt64 = 0,
        clientDisplayLayerNotReadyCount: UInt64 = 0,
        clientPresentationStallCount: UInt64 = 0,
        clientWorstPresentationGapMs: Double = 0,
        clientFrameIntervalP95Ms: Double = 0,
        clientFrameIntervalP99Ms: Double = 0,
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
        self.clientReceivedWorstGapMs = clientReceivedWorstGapMs
        self.clientReceivedFrameIntervalP95Ms = clientReceivedFrameIntervalP95Ms
        self.clientReceivedFrameIntervalP99Ms = clientReceivedFrameIntervalP99Ms
        self.clientSubmitAttemptFPS = clientSubmitAttemptFPS
        self.clientLayerAcceptedFPS = clientLayerAcceptedFPS
        self.clientPresentedFPS = clientPresentedFPS
        self.submittedFPS = submittedFPS
        self.uniqueSubmittedFPS = uniqueSubmittedFPS
        self.pendingFrameCount = pendingFrameCount
        self.clientPendingFrameAgeMs = clientPendingFrameAgeMs
        self.clientOverwrittenPendingFrames = clientOverwrittenPendingFrames
        self.clientDisplayLayerNotReadyCount = clientDisplayLayerNotReadyCount
        self.clientPresentationStallCount = clientPresentationStallCount
        self.clientWorstPresentationGapMs = clientWorstPresentationGapMs
        self.clientFrameIntervalP95Ms = clientFrameIntervalP95Ms
        self.clientFrameIntervalP99Ms = clientFrameIntervalP99Ms
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

    mutating func applyHostCaptureCadence(_ cadence: StreamCaptureCadenceMetrics?) {
        hostCaptureWallClockGapWorstMs = cadence?.wallClockGapWorstMs
        hostCaptureWallClockGapP95Ms = cadence?.wallClockGapP95Ms
        hostCaptureWallClockGapP99Ms = cadence?.wallClockGapP99Ms
        hostCaptureDisplayTimeGapWorstMs = cadence?.displayTimeGapWorstMs
        hostCaptureDisplayTimeGapP95Ms = cadence?.displayTimeGapP95Ms
        hostCaptureDisplayTimeGapP99Ms = cadence?.displayTimeGapP99Ms
        hostCaptureDeliveredFrameGapWorstMs = cadence?.deliveredFrameGapWorstMs
        hostCaptureDeliveredFrameGapP95Ms = cadence?.deliveredFrameGapP95Ms
        hostCaptureDeliveredFrameGapP99Ms = cadence?.deliveredFrameGapP99Ms
        hostCaptureCallbackP95Ms = cadence?.callbackDurationP95Ms
        hostCaptureCallbackP99Ms = cadence?.callbackDurationP99Ms
        hostCaptureLongFrameGapCount = cadence?.longFrameGapCount
        hostCaptureDisplayTimeDriftCount = cadence?.displayTimeDriftCount
        hostCaptureVirtualDisplayTimingSuspect = cadence?.virtualDisplayTimingSuspect
        hostCaptureUsesDisplayRefreshCadence = cadence?.usesDisplayRefreshCadence
        hostCaptureUsesNativeRefreshMinimumFrameInterval = cadence?.usesNativeRefreshMinimumFrameInterval
        hostCaptureMinimumFrameIntervalRate = cadence?.minimumFrameIntervalRate
        hostCaptureDisplayRefreshRate = cadence?.displayRefreshRate
        hostVirtualDisplayID = cadence?.virtualDisplayID
        hostVirtualDisplayRefreshRate = cadence?.virtualDisplayRefreshRate
        hostVirtualDisplayScaleFactor = cadence?.virtualDisplayScaleFactor
        hostCaptureStatusCompleteCount = cadence?.completeFrameStatusCount
        hostCaptureStatusIdleCount = cadence?.idleFrameStatusCount
        hostCaptureStatusBlankCount = cadence?.blankFrameStatusCount
        hostCaptureStatusSuspendedCount = cadence?.suspendedFrameStatusCount
        hostCaptureStatusStartedCount = cadence?.startedFrameStatusCount
        hostCaptureStatusStoppedCount = cadence?.stoppedFrameStatusCount
        hostCaptureStatusUnknownCount = cadence?.unknownFrameStatusCount
        hostCaptureCadenceDropCount = cadence?.cadenceDropCount
        hostCaptureCadenceSampleOverwriteCount = cadence?.sampleOverwriteCount
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
        receivedWorstGapMs: Double = 0,
        receivedFrameIntervalP95Ms: Double = 0,
        receivedFrameIntervalP99Ms: Double = 0,
        droppedFrames: UInt64,
        submitAttemptFPS: Double = 0,
        layerAcceptedFPS: Double = 0,
        presentedFPS: Double = 0,
        submittedFPS: Double,
        uniqueSubmittedFPS: Double,
        pendingFrameCount: Int,
        pendingFrameAgeMs: Double,
        overwrittenPendingFrames: UInt64,
        displayLayerNotReadyCount: UInt64,
        presentationStallCount: UInt64 = 0,
        worstPresentationGapMs: Double = 0,
        frameIntervalP95Ms: Double = 0,
        frameIntervalP99Ms: Double = 0,
        decodeHealthy: Bool
    ) {
        lock.lock()
        var snapshot = metricsByStream[streamID] ?? MirageClientMetricsSnapshot()
        snapshot.decodedFPS = decodedFPS
        snapshot.receivedFPS = receivedFPS
        snapshot.clientReceivedWorstGapMs = max(0, receivedWorstGapMs)
        snapshot.clientReceivedFrameIntervalP95Ms = max(0, receivedFrameIntervalP95Ms)
        snapshot.clientReceivedFrameIntervalP99Ms = max(0, receivedFrameIntervalP99Ms)
        snapshot.clientSubmitAttemptFPS = max(0, submitAttemptFPS)
        snapshot.clientLayerAcceptedFPS = max(0, layerAcceptedFPS)
        snapshot.clientPresentedFPS = max(0, presentedFPS)
        snapshot.submittedFPS = submittedFPS
        snapshot.uniqueSubmittedFPS = uniqueSubmittedFPS
        snapshot.pendingFrameCount = max(0, pendingFrameCount)
        snapshot.clientPendingFrameAgeMs = max(0, pendingFrameAgeMs)
        snapshot.clientOverwrittenPendingFrames = overwrittenPendingFrames
        snapshot.clientDisplayLayerNotReadyCount = displayLayerNotReadyCount
        snapshot.clientPresentationStallCount = presentationStallCount
        snapshot.clientWorstPresentationGapMs = max(0, worstPresentationGapMs)
        snapshot.clientFrameIntervalP95Ms = max(0, frameIntervalP95Ms)
        snapshot.clientFrameIntervalP99Ms = max(0, frameIntervalP99Ms)
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
        captureCadence: StreamCaptureCadenceMetrics?,
        sendQueueBytes: Int?,
        sendStartDelayAverageMs: Double?,
        sendStartDelayMaxMs: Double?,
        sendCompletionAverageMs: Double?,
        sendCompletionMaxMs: Double?,
        packetPacerAverageSleepMs: Double?,
        packetPacerTotalSleepMs: Int?,
        packetPacerMaxSleepMs: Int?,
        packetPacerFrameMaxSleepMs: Int?,
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
        snapshot.applyHostCaptureCadence(captureCadence)
        snapshot.hostSendQueueBytes = sendQueueBytes
        snapshot.hostSendStartDelayAverageMs = sendStartDelayAverageMs
        snapshot.hostSendStartDelayMaxMs = sendStartDelayMaxMs
        snapshot.hostSendCompletionAverageMs = sendCompletionAverageMs
        snapshot.hostSendCompletionMaxMs = sendCompletionMaxMs
        snapshot.hostPacketPacerAverageSleepMs = packetPacerAverageSleepMs
        snapshot.hostPacketPacerTotalSleepMs = packetPacerTotalSleepMs
        snapshot.hostPacketPacerMaxSleepMs = packetPacerMaxSleepMs
        snapshot.hostPacketPacerFrameMaxSleepMs = packetPacerFrameMaxSleepMs
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
