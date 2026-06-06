//
//  MirageStreamMetricsMessages.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore
import MirageMedia

// MARK: - Stream Metrics Messages

/// Capture cadence metrics sampled on the host and reported with stream telemetry.
package struct StreamCaptureCadenceMetrics: Codable, Equatable {
    package let sampleDurationSeconds: Double?
    package let rawScreenCallbackCount: UInt64?
    package let completeFrameCount: UInt64?
    package let renderableFrameCount: UInt64?
    package let idleFrameCount: UInt64?
    package let cadenceAdmittedFrameCount: UInt64?
    package let rawScreenCallbackFPS: Double?
    package let completeFrameFPS: Double?
    package let renderableFrameFPS: Double?
    package let cadenceAdmittedFrameFPS: Double?
    package let observedSCKFPS: Double?
    package let wallClockGapWorstMs: Double
    package let wallClockGapP95Ms: Double
    package let wallClockGapP99Ms: Double
    package let displayTimeGapWorstMs: Double
    package let displayTimeGapP95Ms: Double
    package let displayTimeGapP99Ms: Double
    package let deliveredFrameGapWorstMs: Double
    package let deliveredFrameGapP95Ms: Double
    package let deliveredFrameGapP99Ms: Double
    package let callbackDurationP95Ms: Double
    package let callbackDurationP99Ms: Double
    package let longFrameGapCount: UInt64
    package let displayTimeDriftCount: UInt64
    package let blankFrameStatusCount: UInt64
    package let suspendedFrameStatusCount: UInt64
    package let stoppedFrameStatusCount: UInt64
    package let cadenceDropCount: UInt64
    package let usesDisplayRefreshCadence: Bool?
    package let usesNativeRefreshMinimumFrameInterval: Bool?
    package let minimumFrameIntervalRate: Int?
    package let displayRefreshRate: Int?
    package let virtualDisplayID: UInt32?
    package let virtualDisplayRefreshRate: Double?
    package let virtualDisplayScaleFactor: Double?
    package let virtualDisplayTimingSuspect: Bool?

    package init(
        sampleDurationSeconds: Double? = nil,
        rawScreenCallbackCount: UInt64? = nil,
        completeFrameCount: UInt64? = nil,
        renderableFrameCount: UInt64? = nil,
        idleFrameCount: UInt64? = nil,
        cadenceAdmittedFrameCount: UInt64? = nil,
        rawScreenCallbackFPS: Double? = nil,
        completeFrameFPS: Double? = nil,
        renderableFrameFPS: Double? = nil,
        cadenceAdmittedFrameFPS: Double? = nil,
        observedSCKFPS: Double? = nil,
        wallClockGapWorstMs: Double = 0,
        wallClockGapP95Ms: Double = 0,
        wallClockGapP99Ms: Double = 0,
        displayTimeGapWorstMs: Double = 0,
        displayTimeGapP95Ms: Double = 0,
        displayTimeGapP99Ms: Double = 0,
        deliveredFrameGapWorstMs: Double = 0,
        deliveredFrameGapP95Ms: Double = 0,
        deliveredFrameGapP99Ms: Double = 0,
        callbackDurationP95Ms: Double = 0,
        callbackDurationP99Ms: Double = 0,
        longFrameGapCount: UInt64 = 0,
        displayTimeDriftCount: UInt64 = 0,
        blankFrameStatusCount: UInt64 = 0,
        suspendedFrameStatusCount: UInt64 = 0,
        stoppedFrameStatusCount: UInt64 = 0,
        cadenceDropCount: UInt64 = 0,
        usesDisplayRefreshCadence: Bool? = nil,
        usesNativeRefreshMinimumFrameInterval: Bool? = nil,
        minimumFrameIntervalRate: Int? = nil,
        displayRefreshRate: Int? = nil,
        virtualDisplayID: UInt32? = nil,
        virtualDisplayRefreshRate: Double? = nil,
        virtualDisplayScaleFactor: Double? = nil,
        virtualDisplayTimingSuspect: Bool? = nil
    ) {
        self.sampleDurationSeconds = sampleDurationSeconds
        self.rawScreenCallbackCount = rawScreenCallbackCount
        self.completeFrameCount = completeFrameCount
        self.renderableFrameCount = renderableFrameCount
        self.idleFrameCount = idleFrameCount
        self.cadenceAdmittedFrameCount = cadenceAdmittedFrameCount
        self.rawScreenCallbackFPS = rawScreenCallbackFPS
        self.completeFrameFPS = completeFrameFPS
        self.renderableFrameFPS = renderableFrameFPS
        self.cadenceAdmittedFrameFPS = cadenceAdmittedFrameFPS
        self.observedSCKFPS = observedSCKFPS
        self.wallClockGapWorstMs = wallClockGapWorstMs
        self.wallClockGapP95Ms = wallClockGapP95Ms
        self.wallClockGapP99Ms = wallClockGapP99Ms
        self.displayTimeGapWorstMs = displayTimeGapWorstMs
        self.displayTimeGapP95Ms = displayTimeGapP95Ms
        self.displayTimeGapP99Ms = displayTimeGapP99Ms
        self.deliveredFrameGapWorstMs = deliveredFrameGapWorstMs
        self.deliveredFrameGapP95Ms = deliveredFrameGapP95Ms
        self.deliveredFrameGapP99Ms = deliveredFrameGapP99Ms
        self.callbackDurationP95Ms = callbackDurationP95Ms
        self.callbackDurationP99Ms = callbackDurationP99Ms
        self.longFrameGapCount = longFrameGapCount
        self.displayTimeDriftCount = displayTimeDriftCount
        self.blankFrameStatusCount = blankFrameStatusCount
        self.suspendedFrameStatusCount = suspendedFrameStatusCount
        self.stoppedFrameStatusCount = stoppedFrameStatusCount
        self.cadenceDropCount = cadenceDropCount
        self.usesDisplayRefreshCadence = usesDisplayRefreshCadence
        self.usesNativeRefreshMinimumFrameInterval = usesNativeRefreshMinimumFrameInterval
        self.minimumFrameIntervalRate = minimumFrameIntervalRate
        self.displayRefreshRate = displayRefreshRate
        self.virtualDisplayID = virtualDisplayID
        self.virtualDisplayRefreshRate = virtualDisplayRefreshRate
        self.virtualDisplayScaleFactor = virtualDisplayScaleFactor
        self.virtualDisplayTimingSuspect = virtualDisplayTimingSuspect
    }
}

/// Host-to-client stream metrics sampled per metrics-update window.
package struct StreamMetricsMessage: Codable {
    package let streamID: StreamID
    package let encodedFPS: Double
    package let idleEncodedFPS: Double
    package let droppedFrames: UInt64
    package let activeQuality: Float
    package let targetFrameRate: Int
    package let enteredBitrate: Int?
    package let currentBitrate: Int?
    package let encoderRequestedBitrateBps: Int?
    package let encoderActualBitrateBps: Int?
    package let encoderActualWindowMs: Int?
    package let encodedFrameBytesP50: Int?
    package let encodedFrameBytesP95: Int?
    package let encodedFrameBytesP99: Int?
    package let encodedKeyframeBytesP50: Int?
    package let encodedKeyframeBytesP95: Int?
    package let encodedKeyframeBytesP99: Int?
    package let encoderRateControlStrategy: MirageMedia.MirageEncoderRateControlStrategy?
    package let encoderRateLimitBytes: Int?
    package let encoderRateLimitWindowMs: Int?
    package let effectiveStreamScale: Double?
    package let adaptiveStreamScaleReason: String?
    package let encoderRetuneValidationResult: String?
    package let encoderKeyframeForRetuneCount: UInt64?
    package let encoderSessionRecreationCount: UInt64?
    package let requestedTargetBitrate: Int?
    package let bitrateAdaptationCeiling: Int?
    package let startupBitrate: Int?
    package let realtimeBitrateCeiling: Int?
    package let realtimePressureState: String?
    package let realtimePressureReason: String?
    package let awdlPolicyState: String?
    package let awdlPolicyTrigger: String?
    package let awdlSelectedLever: String?
    package let awdlPlayoutDelayMs: Double?
    package let awdlResolutionScale: Double?
    package let awdlQualityReductionAllowed: Bool?
    package let awdlHostPacingBudgetBps: Int?
    package let captureAdmissionDrops: UInt64?
    package let frameBudgetMs: Double?
    package let averageEncodeMs: Double?
    package let captureIngressFPS: Double?
    package let captureFPS: Double?
    package let encodeAttemptFPS: Double?
    package let captureCadence: StreamCaptureCadenceMetrics?
    package let sendQueueBytes: Int?
    package let sendStartDelayAverageMs: Double?
    package let sendStartDelayMaxMs: Double?
    package let sendCompletionAverageMs: Double?
    package let sendCompletionMaxMs: Double?
    package let nonKeyframeSendStartDelayMaxMs: Double?
    package let nonKeyframeSendCompletionMaxMs: Double?
    package let packetPacerAverageSleepMs: Double?
    package let packetPacerTotalSleepMs: Int?
    package let packetPacerMaxSleepMs: Int?
    package let packetPacerFrameMaxSleepMs: Int?
    package let mediaMaxPacketSize: Int?
    package let mediaSendProfile: String?
    package let stalePacketDrops: UInt64?
    package let senderLocalDeadlineDrops: UInt64?
    package let generationAbortDrops: UInt64?
    package let nonKeyframeHoldDrops: UInt64?
    package let queuedUnreliableDeadlineExpiredDrops: UInt64?
    package let queuedUnreliableQueueLimitDrops: UInt64?
    package let queuedUnreliableSupersededDrops: UInt64?
    package let queuedUnreliableUnsupportedTransportDrops: UInt64?
    package let queuedUnreliableClosedDrops: UInt64?
    package let queuedUnreliablePendingPackets: Int?
    package let queuedUnreliableOutstandingPackets: Int?
    package let queuedUnreliableQueuedBytes: Int?
    package let queuedUnreliablePendingPacketMax: Int?
    package let queuedUnreliableOutstandingPacketMax: Int?
    package let queuedUnreliableQueuedBytesMax: Int?
    package let queuedUnreliableEnqueuedCount: UInt64?
    package let queuedUnreliableSentCount: UInt64?
    package let queuedUnreliableCompletedCount: UInt64?
    package let queuedUnreliableDroppedCount: UInt64?
    package let queuedUnreliableErrorCount: UInt64?
    package let queuedUnreliableQueueDwellP50Ms: Double?
    package let queuedUnreliableQueueDwellP95Ms: Double?
    package let queuedUnreliableQueueDwellP99Ms: Double?
    package let queuedUnreliableSendGapP50Ms: Double?
    package let queuedUnreliableSendGapP95Ms: Double?
    package let queuedUnreliableSendGapP99Ms: Double?
    package let queuedUnreliableContentProcessedP50Ms: Double?
    package let queuedUnreliableContentProcessedP95Ms: Double?
    package let queuedUnreliableContentProcessedP99Ms: Double?
    package let usingHardwareEncoder: Bool?
    package let encoderGPURegistryID: UInt64?
    package let encodedWidth: Int?
    package let encodedHeight: Int?
    package let capturePixelFormat: String?
    package let captureColorPrimaries: String?
    package let encoderPixelFormat: String?
    package let encoderChromaSampling: String?
    package let encoderProfile: String?
    package let encoderColorPrimaries: String?
    package let encoderTransferFunction: String?
    package let encoderYCbCrMatrix: String?
    package let displayP3CoverageStatus: MirageMedia.MirageDisplayP3CoverageStatus?
    package let tenBitDisplayP3Validated: Bool?
    package let ultra444Validated: Bool?

    package init(
        streamID: StreamID,
        encodedFPS: Double,
        idleEncodedFPS: Double,
        droppedFrames: UInt64,
        activeQuality: Float,
        targetFrameRate: Int,
        enteredBitrate: Int? = nil,
        currentBitrate: Int? = nil,
        encoderRequestedBitrateBps: Int? = nil,
        encoderActualBitrateBps: Int? = nil,
        encoderActualWindowMs: Int? = nil,
        encodedFrameBytesP50: Int? = nil,
        encodedFrameBytesP95: Int? = nil,
        encodedFrameBytesP99: Int? = nil,
        encodedKeyframeBytesP50: Int? = nil,
        encodedKeyframeBytesP95: Int? = nil,
        encodedKeyframeBytesP99: Int? = nil,
        encoderRateControlStrategy: MirageMedia.MirageEncoderRateControlStrategy? = nil,
        encoderRateLimitBytes: Int? = nil,
        encoderRateLimitWindowMs: Int? = nil,
        effectiveStreamScale: Double? = nil,
        adaptiveStreamScaleReason: String? = nil,
        encoderRetuneValidationResult: String? = nil,
        encoderKeyframeForRetuneCount: UInt64? = nil,
        encoderSessionRecreationCount: UInt64? = nil,
        requestedTargetBitrate: Int? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        startupBitrate: Int? = nil,
        realtimeBitrateCeiling: Int? = nil,
        realtimePressureState: String? = nil,
        realtimePressureReason: String? = nil,
        awdlPolicyState: String? = nil,
        awdlPolicyTrigger: String? = nil,
        awdlSelectedLever: String? = nil,
        awdlPlayoutDelayMs: Double? = nil,
        awdlResolutionScale: Double? = nil,
        awdlQualityReductionAllowed: Bool? = nil,
        awdlHostPacingBudgetBps: Int? = nil,
        captureAdmissionDrops: UInt64? = nil,
        frameBudgetMs: Double? = nil,
        averageEncodeMs: Double? = nil,
        captureIngressFPS: Double? = nil,
        captureFPS: Double? = nil,
        encodeAttemptFPS: Double? = nil,
        captureCadence: StreamCaptureCadenceMetrics? = nil,
        sendQueueBytes: Int? = nil,
        sendStartDelayAverageMs: Double? = nil,
        sendStartDelayMaxMs: Double? = nil,
        sendCompletionAverageMs: Double? = nil,
        sendCompletionMaxMs: Double? = nil,
        nonKeyframeSendStartDelayMaxMs: Double? = nil,
        nonKeyframeSendCompletionMaxMs: Double? = nil,
        packetPacerAverageSleepMs: Double? = nil,
        packetPacerTotalSleepMs: Int? = nil,
        packetPacerMaxSleepMs: Int? = nil,
        packetPacerFrameMaxSleepMs: Int? = nil,
        mediaMaxPacketSize: Int? = nil,
        mediaSendProfile: String? = nil,
        stalePacketDrops: UInt64? = nil,
        senderLocalDeadlineDrops: UInt64? = nil,
        generationAbortDrops: UInt64? = nil,
        nonKeyframeHoldDrops: UInt64? = nil,
        queuedUnreliableDeadlineExpiredDrops: UInt64? = nil,
        queuedUnreliableQueueLimitDrops: UInt64? = nil,
        queuedUnreliableSupersededDrops: UInt64? = nil,
        queuedUnreliableUnsupportedTransportDrops: UInt64? = nil,
        queuedUnreliableClosedDrops: UInt64? = nil,
        queuedUnreliablePendingPackets: Int? = nil,
        queuedUnreliableOutstandingPackets: Int? = nil,
        queuedUnreliableQueuedBytes: Int? = nil,
        queuedUnreliablePendingPacketMax: Int? = nil,
        queuedUnreliableOutstandingPacketMax: Int? = nil,
        queuedUnreliableQueuedBytesMax: Int? = nil,
        queuedUnreliableEnqueuedCount: UInt64? = nil,
        queuedUnreliableSentCount: UInt64? = nil,
        queuedUnreliableCompletedCount: UInt64? = nil,
        queuedUnreliableDroppedCount: UInt64? = nil,
        queuedUnreliableErrorCount: UInt64? = nil,
        queuedUnreliableQueueDwellP50Ms: Double? = nil,
        queuedUnreliableQueueDwellP95Ms: Double? = nil,
        queuedUnreliableQueueDwellP99Ms: Double? = nil,
        queuedUnreliableSendGapP50Ms: Double? = nil,
        queuedUnreliableSendGapP95Ms: Double? = nil,
        queuedUnreliableSendGapP99Ms: Double? = nil,
        queuedUnreliableContentProcessedP50Ms: Double? = nil,
        queuedUnreliableContentProcessedP95Ms: Double? = nil,
        queuedUnreliableContentProcessedP99Ms: Double? = nil,
        usingHardwareEncoder: Bool? = nil,
        encoderGPURegistryID: UInt64? = nil,
        encodedWidth: Int? = nil,
        encodedHeight: Int? = nil,
        capturePixelFormat: String? = nil,
        captureColorPrimaries: String? = nil,
        encoderPixelFormat: String? = nil,
        encoderChromaSampling: String? = nil,
        encoderProfile: String? = nil,
        encoderColorPrimaries: String? = nil,
        encoderTransferFunction: String? = nil,
        encoderYCbCrMatrix: String? = nil,
        displayP3CoverageStatus: MirageMedia.MirageDisplayP3CoverageStatus? = nil,
        tenBitDisplayP3Validated: Bool? = nil,
        ultra444Validated: Bool? = nil
    ) {
        self.streamID = streamID
        self.encodedFPS = encodedFPS
        self.idleEncodedFPS = idleEncodedFPS
        self.droppedFrames = droppedFrames
        self.activeQuality = activeQuality
        self.targetFrameRate = targetFrameRate
        self.enteredBitrate = enteredBitrate
        self.currentBitrate = currentBitrate
        self.encoderRequestedBitrateBps = encoderRequestedBitrateBps
        self.encoderActualBitrateBps = encoderActualBitrateBps
        self.encoderActualWindowMs = encoderActualWindowMs
        self.encodedFrameBytesP50 = encodedFrameBytesP50
        self.encodedFrameBytesP95 = encodedFrameBytesP95
        self.encodedFrameBytesP99 = encodedFrameBytesP99
        self.encodedKeyframeBytesP50 = encodedKeyframeBytesP50
        self.encodedKeyframeBytesP95 = encodedKeyframeBytesP95
        self.encodedKeyframeBytesP99 = encodedKeyframeBytesP99
        self.encoderRateControlStrategy = encoderRateControlStrategy
        self.encoderRateLimitBytes = encoderRateLimitBytes
        self.encoderRateLimitWindowMs = encoderRateLimitWindowMs
        self.effectiveStreamScale = effectiveStreamScale
        self.adaptiveStreamScaleReason = adaptiveStreamScaleReason
        self.encoderRetuneValidationResult = encoderRetuneValidationResult
        self.encoderKeyframeForRetuneCount = encoderKeyframeForRetuneCount
        self.encoderSessionRecreationCount = encoderSessionRecreationCount
        self.requestedTargetBitrate = requestedTargetBitrate
        self.bitrateAdaptationCeiling = bitrateAdaptationCeiling
        self.startupBitrate = startupBitrate
        self.realtimeBitrateCeiling = realtimeBitrateCeiling
        self.realtimePressureState = realtimePressureState
        self.realtimePressureReason = realtimePressureReason
        self.awdlPolicyState = awdlPolicyState
        self.awdlPolicyTrigger = awdlPolicyTrigger
        self.awdlSelectedLever = awdlSelectedLever
        self.awdlPlayoutDelayMs = awdlPlayoutDelayMs
        self.awdlResolutionScale = awdlResolutionScale
        self.awdlQualityReductionAllowed = awdlQualityReductionAllowed
        self.awdlHostPacingBudgetBps = awdlHostPacingBudgetBps
        self.captureAdmissionDrops = captureAdmissionDrops
        self.frameBudgetMs = frameBudgetMs
        self.averageEncodeMs = averageEncodeMs
        self.captureIngressFPS = captureIngressFPS
        self.captureFPS = captureFPS
        self.encodeAttemptFPS = encodeAttemptFPS
        self.captureCadence = captureCadence
        self.sendQueueBytes = sendQueueBytes
        self.sendStartDelayAverageMs = sendStartDelayAverageMs
        self.sendStartDelayMaxMs = sendStartDelayMaxMs
        self.sendCompletionAverageMs = sendCompletionAverageMs
        self.sendCompletionMaxMs = sendCompletionMaxMs
        self.nonKeyframeSendStartDelayMaxMs = nonKeyframeSendStartDelayMaxMs
        self.nonKeyframeSendCompletionMaxMs = nonKeyframeSendCompletionMaxMs
        self.packetPacerAverageSleepMs = packetPacerAverageSleepMs
        self.packetPacerTotalSleepMs = packetPacerTotalSleepMs
        self.packetPacerMaxSleepMs = packetPacerMaxSleepMs
        self.packetPacerFrameMaxSleepMs = packetPacerFrameMaxSleepMs
        self.mediaMaxPacketSize = mediaMaxPacketSize
        self.mediaSendProfile = mediaSendProfile
        self.stalePacketDrops = stalePacketDrops
        self.senderLocalDeadlineDrops = senderLocalDeadlineDrops
        self.generationAbortDrops = generationAbortDrops
        self.nonKeyframeHoldDrops = nonKeyframeHoldDrops
        self.queuedUnreliableDeadlineExpiredDrops = queuedUnreliableDeadlineExpiredDrops
        self.queuedUnreliableQueueLimitDrops = queuedUnreliableQueueLimitDrops
        self.queuedUnreliableSupersededDrops = queuedUnreliableSupersededDrops
        self.queuedUnreliableUnsupportedTransportDrops = queuedUnreliableUnsupportedTransportDrops
        self.queuedUnreliableClosedDrops = queuedUnreliableClosedDrops
        self.queuedUnreliablePendingPackets = queuedUnreliablePendingPackets
        self.queuedUnreliableOutstandingPackets = queuedUnreliableOutstandingPackets
        self.queuedUnreliableQueuedBytes = queuedUnreliableQueuedBytes
        self.queuedUnreliablePendingPacketMax = queuedUnreliablePendingPacketMax
        self.queuedUnreliableOutstandingPacketMax = queuedUnreliableOutstandingPacketMax
        self.queuedUnreliableQueuedBytesMax = queuedUnreliableQueuedBytesMax
        self.queuedUnreliableEnqueuedCount = queuedUnreliableEnqueuedCount
        self.queuedUnreliableSentCount = queuedUnreliableSentCount
        self.queuedUnreliableCompletedCount = queuedUnreliableCompletedCount
        self.queuedUnreliableDroppedCount = queuedUnreliableDroppedCount
        self.queuedUnreliableErrorCount = queuedUnreliableErrorCount
        self.queuedUnreliableQueueDwellP50Ms = queuedUnreliableQueueDwellP50Ms
        self.queuedUnreliableQueueDwellP95Ms = queuedUnreliableQueueDwellP95Ms
        self.queuedUnreliableQueueDwellP99Ms = queuedUnreliableQueueDwellP99Ms
        self.queuedUnreliableSendGapP50Ms = queuedUnreliableSendGapP50Ms
        self.queuedUnreliableSendGapP95Ms = queuedUnreliableSendGapP95Ms
        self.queuedUnreliableSendGapP99Ms = queuedUnreliableSendGapP99Ms
        self.queuedUnreliableContentProcessedP50Ms = queuedUnreliableContentProcessedP50Ms
        self.queuedUnreliableContentProcessedP95Ms = queuedUnreliableContentProcessedP95Ms
        self.queuedUnreliableContentProcessedP99Ms = queuedUnreliableContentProcessedP99Ms
        self.usingHardwareEncoder = usingHardwareEncoder
        self.encoderGPURegistryID = encoderGPURegistryID
        self.encodedWidth = encodedWidth
        self.encodedHeight = encodedHeight
        self.capturePixelFormat = capturePixelFormat
        self.captureColorPrimaries = captureColorPrimaries
        self.encoderPixelFormat = encoderPixelFormat
        self.encoderChromaSampling = encoderChromaSampling
        self.encoderProfile = encoderProfile
        self.encoderColorPrimaries = encoderColorPrimaries
        self.encoderTransferFunction = encoderTransferFunction
        self.encoderYCbCrMatrix = encoderYCbCrMatrix
        self.displayP3CoverageStatus = displayP3CoverageStatus
        self.tenBitDisplayP3Validated = tenBitDisplayP3Validated
        self.ultra444Validated = ultra444Validated
    }
}

extension StreamMetricsMessage {
    package var queuedUnreliableDropCount: UInt64 {
        (queuedUnreliableDeadlineExpiredDrops ?? 0) +
            (queuedUnreliableQueueLimitDrops ?? 0) +
            (queuedUnreliableSupersededDrops ?? 0) +
            (queuedUnreliableUnsupportedTransportDrops ?? 0) +
            (queuedUnreliableClosedDrops ?? 0)
    }

    package var transportPressureDropCount: UInt64 {
        (stalePacketDrops ?? 0) +
            (senderLocalDeadlineDrops ?? 0) +
            queuedUnreliableDropCount
    }
}
