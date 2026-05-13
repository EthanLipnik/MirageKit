//
//  MessageTypes+StreamMetrics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation

// MARK: - Stream Metrics Messages

/// Capture cadence metrics sampled on the host and reported with stream telemetry.
package struct StreamCaptureCadenceMetrics: Codable, Equatable {
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
    package let requestedTargetBitrate: Int?
    package let bitrateAdaptationCeiling: Int?
    package let startupBitrate: Int?
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
    package let stalePacketDrops: UInt64?
    package let senderLocalDeadlineDrops: UInt64?
    package let generationAbortDrops: UInt64?
    package let nonKeyframeHoldDrops: UInt64?
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
    package let displayP3CoverageStatus: MirageDisplayP3CoverageStatus?
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
        requestedTargetBitrate: Int? = nil,
        bitrateAdaptationCeiling: Int? = nil,
        startupBitrate: Int? = nil,
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
        stalePacketDrops: UInt64? = nil,
        senderLocalDeadlineDrops: UInt64? = nil,
        generationAbortDrops: UInt64? = nil,
        nonKeyframeHoldDrops: UInt64? = nil,
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
        displayP3CoverageStatus: MirageDisplayP3CoverageStatus? = nil,
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
        self.requestedTargetBitrate = requestedTargetBitrate
        self.bitrateAdaptationCeiling = bitrateAdaptationCeiling
        self.startupBitrate = startupBitrate
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
        self.stalePacketDrops = stalePacketDrops
        self.senderLocalDeadlineDrops = senderLocalDeadlineDrops
        self.generationAbortDrops = generationAbortDrops
        self.nonKeyframeHoldDrops = nonKeyframeHoldDrops
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
