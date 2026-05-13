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
            snapshot.hostRequestedTargetBitrate = metrics.requestedTargetBitrate
            snapshot.hostBitrateAdaptationCeiling = metrics.bitrateAdaptationCeiling
            snapshot.hostStartupBitrate = metrics.startupBitrate
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
            snapshot.hostStalePacketDrops = metrics.stalePacketDrops
            snapshot.hostSenderLocalDeadlineDrops = metrics.senderLocalDeadlineDrops
            snapshot.hostGenerationAbortDrops = metrics.generationAbortDrops
            snapshot.hostNonKeyframeHoldDrops = metrics.nonKeyframeHoldDrops
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
