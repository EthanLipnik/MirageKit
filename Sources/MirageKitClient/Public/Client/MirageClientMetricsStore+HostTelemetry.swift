//
//  MirageClientMetricsStore+HostTelemetry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

extension MirageClientMetricsStore {
    /// Updates host encode and capture metrics received over the control channel.
    package func updateHostMetrics(_ metrics: StreamMetricsMessage) {
        updateSnapshot(for: metrics.streamID) { snapshot in
            snapshot.hostEncodedFPS = metrics.encodedFPS
            snapshot.hostIdleFPS = metrics.idleEncodedFPS
            snapshot.hostDroppedFrames = metrics.droppedFrames
            snapshot.hostActiveQuality = Double(metrics.activeQuality)
            snapshot.hostTargetFrameRate = metrics.targetFrameRate
            snapshot.hostEnteredBitrate = metrics.enteredBitrate
            snapshot.hostCurrentBitrate = metrics.currentBitrate
            snapshot.hostEncoderRequestedBitrateBps = metrics.encoderRequestedBitrateBps
            snapshot.hostEncoderActualBitrateBps = metrics.encoderActualBitrateBps
            snapshot.hostEncoderActualWindowMs = metrics.encoderActualWindowMs
            snapshot.hostEncodedFrameBytesP50 = metrics.encodedFrameBytesP50
            snapshot.hostEncodedFrameBytesP95 = metrics.encodedFrameBytesP95
            snapshot.hostEncodedFrameBytesP99 = metrics.encodedFrameBytesP99
            snapshot.hostEncodedKeyframeBytesP50 = metrics.encodedKeyframeBytesP50
            snapshot.hostEncodedKeyframeBytesP95 = metrics.encodedKeyframeBytesP95
            snapshot.hostEncodedKeyframeBytesP99 = metrics.encodedKeyframeBytesP99
            snapshot.hostEncoderRateControlStrategy = metrics.encoderRateControlStrategy
            snapshot.hostEncoderRateLimitBytes = metrics.encoderRateLimitBytes
            snapshot.hostEncoderRateLimitWindowMs = metrics.encoderRateLimitWindowMs
            snapshot.hostEffectiveStreamScale = metrics.effectiveStreamScale
            snapshot.hostAdaptiveStreamScaleReason = metrics.adaptiveStreamScaleReason
            snapshot.hostEncoderRetuneValidationResult = metrics.encoderRetuneValidationResult
            snapshot.hostEncoderKeyframeForRetuneCount = metrics.encoderKeyframeForRetuneCount
            snapshot.hostEncoderSessionRecreationCount = metrics.encoderSessionRecreationCount
            snapshot.hostRequestedTargetBitrate = metrics.requestedTargetBitrate
            snapshot.hostBitrateAdaptationCeiling = metrics.bitrateAdaptationCeiling
            snapshot.hostStartupBitrate = metrics.startupBitrate
            snapshot.hostRealtimeBitrateCeiling = metrics.realtimeBitrateCeiling
            snapshot.hostRealtimePressureState = metrics.realtimePressureState
            snapshot.hostRealtimeControlRevision = metrics.realtimeControlRevision
            snapshot.hostRealtimePressureReason = metrics.realtimePressureReason
            snapshot.hostRealtimeDeliveryMode = metrics.realtimeDeliveryMode
            snapshot.hostRealtimeRequiredBitrateForQualityBps = metrics.realtimeRequiredBitrateForQualityBps
            snapshot.hostRealtimeObservedPFrameWireBytesP95 = metrics.realtimeObservedPFrameWireBytesP95
            snapshot.hostAwdlPolicyState = metrics.awdlPolicyState
            snapshot.hostAwdlPolicyTrigger = metrics.awdlPolicyTrigger
            snapshot.hostAwdlSelectedLever = metrics.awdlSelectedLever
            snapshot.hostAwdlPlayoutDelayMs = metrics.awdlPlayoutDelayMs
            snapshot.hostAwdlResolutionScale = metrics.awdlResolutionScale
            snapshot.hostAwdlQualityReductionAllowed = metrics.awdlQualityReductionAllowed
            snapshot.hostAwdlPacingBudgetBps = metrics.awdlHostPacingBudgetBps
            snapshot.hostCaptureAdmissionDrops = metrics.captureAdmissionDrops
            snapshot.hostFrameBudgetMs = metrics.frameBudgetMs
            snapshot.hostAverageEncodeMs = metrics.averageEncodeMs
            snapshot.hostCaptureIngressFPS = metrics.captureIngressFPS
            snapshot.hostCaptureFPS = metrics.captureFPS
            snapshot.hostEncodeAttemptFPS = metrics.encodeAttemptFPS
            snapshot.hostUsingHardwareEncoder = metrics.usingHardwareEncoder
            snapshot.hostEncoderGPURegistryID = metrics.encoderGPURegistryID
            snapshot.hostEncodedWidth = metrics.encodedWidth
            snapshot.hostEncodedHeight = metrics.encodedHeight
            snapshot.hostCapturePixelFormat = metrics.capturePixelFormat
            snapshot.hostCaptureColorPrimaries = metrics.captureColorPrimaries
            snapshot.hostEncoderPixelFormat = metrics.encoderPixelFormat
            snapshot.hostEncoderChromaSampling = metrics.encoderChromaSampling
            snapshot.hostEncoderProfile = metrics.encoderProfile
            snapshot.hostEncoderColorPrimaries = metrics.encoderColorPrimaries
            snapshot.hostEncoderTransferFunction = metrics.encoderTransferFunction
            snapshot.hostEncoderYCbCrMatrix = metrics.encoderYCbCrMatrix
            snapshot.hostDisplayP3CoverageStatus = metrics.displayP3CoverageStatus
            snapshot.hostTenBitDisplayP3Validated = metrics.tenBitDisplayP3Validated
            snapshot.hostUltra444Validated = metrics.ultra444Validated
            snapshot.hasHostMetrics = true
        }
    }

    /// Updates host pipeline timing and packet-sender metrics received over the control channel.
    package func updateHostPipelineMetrics(_ metrics: StreamMetricsMessage) {
        updateSnapshot(for: metrics.streamID) { snapshot in
            snapshot.applyHostCaptureCadence(metrics.captureCadence)
            snapshot.hostSendQueueBytes = metrics.sendQueueBytes
            snapshot.hostSendStartDelayAverageMs = metrics.sendStartDelayAverageMs
            snapshot.hostSendStartDelayMaxMs = metrics.sendStartDelayMaxMs
            snapshot.hostSendCompletionAverageMs = metrics.sendCompletionAverageMs
            snapshot.hostSendCompletionMaxMs = metrics.sendCompletionMaxMs
            snapshot.hostPacketPacerAverageSleepMs = metrics.packetPacerAverageSleepMs
            snapshot.hostPacketPacerTotalSleepMs = metrics.packetPacerTotalSleepMs
            snapshot.hostPacketPacerMaxSleepMs = metrics.packetPacerMaxSleepMs
            snapshot.hostPacketPacerFrameMaxSleepMs = metrics.packetPacerFrameMaxSleepMs
            snapshot.hostMediaMaxPacketSize = metrics.mediaMaxPacketSize
            snapshot.hostMediaSendProfile = metrics.mediaSendProfile
            snapshot.hostStalePacketDrops = metrics.stalePacketDrops
            snapshot.hostSenderLocalDeadlineDrops = metrics.senderLocalDeadlineDrops
            snapshot.hostGenerationAbortDrops = metrics.generationAbortDrops
            snapshot.hostNonKeyframeHoldDrops = metrics.nonKeyframeHoldDrops
            snapshot.hostQueuedUnreliableDeadlineExpiredDrops = metrics.queuedUnreliableDeadlineExpiredDrops
            snapshot.hostQueuedUnreliableQueueLimitDrops = metrics.queuedUnreliableQueueLimitDrops
            snapshot.hostQueuedUnreliableSupersededDrops = metrics.queuedUnreliableSupersededDrops
            snapshot.hostQueuedUnreliableUnsupportedTransportDrops = metrics.queuedUnreliableUnsupportedTransportDrops
            snapshot.hostQueuedUnreliableClosedDrops = metrics.queuedUnreliableClosedDrops
            snapshot.hostQueuedUnreliablePendingPackets = metrics.queuedUnreliablePendingPackets
            snapshot.hostQueuedUnreliableOutstandingPackets = metrics.queuedUnreliableOutstandingPackets
            snapshot.hostQueuedUnreliableQueuedBytes = metrics.queuedUnreliableQueuedBytes
            snapshot.hostQueuedUnreliablePendingPacketMax = metrics.queuedUnreliablePendingPacketMax
            snapshot.hostQueuedUnreliableOutstandingPacketMax = metrics.queuedUnreliableOutstandingPacketMax
            snapshot.hostQueuedUnreliableQueuedBytesMax = metrics.queuedUnreliableQueuedBytesMax
            snapshot.hostQueuedUnreliableEnqueuedCount = metrics.queuedUnreliableEnqueuedCount
            snapshot.hostQueuedUnreliableSentCount = metrics.queuedUnreliableSentCount
            snapshot.hostQueuedUnreliableCompletedCount = metrics.queuedUnreliableCompletedCount
            snapshot.hostQueuedUnreliableDroppedCount = metrics.queuedUnreliableDroppedCount
            snapshot.hostQueuedUnreliableErrorCount = metrics.queuedUnreliableErrorCount
            snapshot.hostQueuedUnreliableQueueDwellP50Ms = metrics.queuedUnreliableQueueDwellP50Ms
            snapshot.hostQueuedUnreliableQueueDwellP95Ms = metrics.queuedUnreliableQueueDwellP95Ms
            snapshot.hostQueuedUnreliableQueueDwellP99Ms = metrics.queuedUnreliableQueueDwellP99Ms
            snapshot.hostQueuedUnreliableSendGapP50Ms = metrics.queuedUnreliableSendGapP50Ms
            snapshot.hostQueuedUnreliableSendGapP95Ms = metrics.queuedUnreliableSendGapP95Ms
            snapshot.hostQueuedUnreliableSendGapP99Ms = metrics.queuedUnreliableSendGapP99Ms
            snapshot.hostQueuedUnreliableContentProcessedP50Ms = metrics.queuedUnreliableContentProcessedP50Ms
            snapshot.hostQueuedUnreliableContentProcessedP95Ms = metrics.queuedUnreliableContentProcessedP95Ms
            snapshot.hostQueuedUnreliableContentProcessedP99Ms = metrics.queuedUnreliableContentProcessedP99Ms
        }
    }

    /// Records decoder implementation telemetry for one stream.
    public func updateClientDecoderTelemetry(
        streamID: StreamID,
        outputPixelFormat: String?,
        usingHardwareDecoder: Bool?
    ) {
        updateSnapshot(for: streamID) { snapshot in
            snapshot.clientDecoderOutputPixelFormat = outputPixelFormat
            snapshot.clientUsingHardwareDecoder = usingHardwareDecoder
        }
    }
}
