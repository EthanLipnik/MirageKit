//
//  MessageTypes+Window.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import CoreGraphics
import Foundation

// MARK: - Window Messages

package enum MirageStartupStreamKind: String, Codable, Sendable {
    case window
    case desktop
    case custom
    case appAtlas
}

package struct WindowListMessage: Codable {
    package let windows: [MirageWindow]

    package init(windows: [MirageWindow]) {
        self.windows = windows
    }
}

package struct WindowUpdateMessage: Codable {
    package let added: [MirageWindow]
    package let removed: [WindowID]
    package let updated: [MirageWindow]

    package init(added: [MirageWindow], removed: [WindowID], updated: [MirageWindow]) {
        self.added = added
        self.removed = removed
        self.updated = updated
    }
}

package struct StartStreamMessage: Codable {
    package let windowID: WindowID
    /// UDP port the client is listening on for video data
    package let dataPort: UInt16?
    /// Client-selected target frame rate in Hz.
    package let targetFrameRate: Int
    /// Client's display scale factor (e.g., 2.0 for Retina Mac, ~1.72 for iPad Pro)
    /// If nil, host uses its own scale factor.
    package var scaleFactor: CGFloat?
    /// Client's requested pixel dimensions (optional, for initial stream setup)
    /// If nil, host uses window size × scaleFactor
    package var pixelWidth: Int?
    package var pixelHeight: Int?
    /// Client's logical display size in points (view bounds) for virtual display sizing
    /// Host applies HiDPI (2x) to determine virtual display pixel resolution
    package var displayWidth: Int?
    package var displayHeight: Int?
    /// Client-requested keyframe interval in frames
    /// Higher values (e.g., 600 = 10 seconds @ 60fps) reduce periodic lag spikes
    /// If nil, host uses default from encoder configuration
    package var keyFrameInterval: Int?
    /// Client-requested ScreenCaptureKit queue depth
    package var captureQueueDepth: Int?
    /// Client-requested stream color depth preset.
    package var colorDepth: MirageStreamColorDepth?
    /// Client-requested target bitrate (bits per second)
    package var bitrate: Int?
    /// Client-requested latency preference for host buffering and render behavior.
    package var latencyMode: MirageStreamLatencyMode?
    /// Client-requested runtime quality adaptation behavior on host.
    package var allowRuntimeQualityAdjustment: Bool?
    /// Client-requested compression boost for highest-resolution lowest-latency streams.
    package var lowLatencyHighResolutionCompressionBoost: Bool?
    /// Client-requested override to bypass host/client resolution caps.
    package var disableResolutionCap: Bool?
    /// Client-requested stream scale (0.1-1.0)
    /// Applies post-capture downscaling without resizing the host window
    package var streamScale: CGFloat?
    /// Client audio streaming configuration
    package var audioConfiguration: MirageAudioConfiguration?
    /// Maximum bitrate the in-stream adaptation governor may ramp toward.
    package var bitrateAdaptationCeiling: Int?
    /// Maximum encoded width in pixels for host-computed stream scaling.
    package var encoderMaxWidth: Int?
    /// Maximum encoded height in pixels for host-computed stream scaling.
    package var encoderMaxHeight: Int?
    /// Requested media packet size for this stream.
    package var mediaMaxPacketSize: Int?
    /// Client-requested MetalFX upscaling mode.
    package var upscalingMode: MirageUpscalingMode?
    /// Client-requested video codec.
    package var codec: MirageVideoCodec?

    enum CodingKeys: String, CodingKey {
        case windowID
        case dataPort
        case targetFrameRate
        case scaleFactor
        case pixelWidth
        case pixelHeight
        case displayWidth
        case displayHeight
        case keyFrameInterval
        case captureQueueDepth
        case colorDepth
        case bitrate
        case latencyMode
        case allowRuntimeQualityAdjustment
        case lowLatencyHighResolutionCompressionBoost
        case disableResolutionCap
        case streamScale
        case audioConfiguration
        case bitrateAdaptationCeiling
        case encoderMaxWidth
        case encoderMaxHeight
        case mediaMaxPacketSize
        case upscalingMode
        case codec
    }

    package init(
        windowID: WindowID,
        dataPort: UInt16? = nil,
        targetFrameRate: Int,
        scaleFactor: CGFloat? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        displayWidth: Int? = nil,
        displayHeight: Int? = nil,
        keyFrameInterval: Int? = nil,
        captureQueueDepth: Int? = nil,
        colorDepth: MirageStreamColorDepth? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        disableResolutionCap: Bool? = nil,
        streamScale: CGFloat? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        mediaMaxPacketSize: Int? = nil
    ) {
        self.windowID = windowID
        self.dataPort = dataPort
        self.targetFrameRate = targetFrameRate
        self.scaleFactor = scaleFactor
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.keyFrameInterval = keyFrameInterval
        self.captureQueueDepth = captureQueueDepth
        self.colorDepth = colorDepth
        self.bitrate = bitrate
        self.latencyMode = latencyMode
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        self.disableResolutionCap = disableResolutionCap
        self.streamScale = streamScale
        self.audioConfiguration = audioConfiguration
        self.mediaMaxPacketSize = mediaMaxPacketSize
    }
}

package struct StopStreamMessage: Codable {
    package enum Origin: String, Codable, Sendable {
        case clientWindowClosed
        case remoteCommand
    }

    package let streamID: StreamID
    /// Whether to minimize the source window on the host after stopping the stream
    package var minimizeWindow: Bool = false
    /// Why the stop request was issued. Nil represents the default request path.
    package var origin: Origin?

    package init(streamID: StreamID, minimizeWindow: Bool = false, origin: Origin? = nil) {
        self.streamID = streamID
        self.minimizeWindow = minimizeWindow
        self.origin = origin
    }
}

package struct StreamStartedMessage: Codable {
    package let streamID: StreamID
    package let windowID: WindowID
    package let width: Int
    package let height: Int
    package let frameRate: Int
    package let codec: MirageVideoCodec
    package let startupAttemptID: UUID?
    /// Minimum window size in points - client should not resize smaller
    package var minWidth: Int?
    package var minHeight: Int?
    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Client should update its reassembler with this token.
    package var dimensionToken: UInt16?
    /// Media packet size accepted by the host for this stream.
    package var acceptedMediaMaxPacketSize: Int?

    package init(
        streamID: StreamID,
        windowID: WindowID,
        width: Int,
        height: Int,
        frameRate: Int,
        codec: MirageVideoCodec,
        startupAttemptID: UUID? = nil,
        minWidth: Int? = nil,
        minHeight: Int? = nil,
        dimensionToken: UInt16? = nil,
        acceptedMediaMaxPacketSize: Int? = nil
    ) {
        self.streamID = streamID
        self.windowID = windowID
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.startupAttemptID = startupAttemptID
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.dimensionToken = dimensionToken
        self.acceptedMediaMaxPacketSize = acceptedMediaMaxPacketSize
    }
}

package struct StreamReadyMessage: Codable, Sendable {
    package let streamID: StreamID
    package let startupAttemptID: UUID
    package let kind: MirageStartupStreamKind

    package init(
        streamID: StreamID,
        startupAttemptID: UUID,
        kind: MirageStartupStreamKind
    ) {
        self.streamID = streamID
        self.startupAttemptID = startupAttemptID
        self.kind = kind
    }
}

package struct StreamStoppedMessage: Codable {
    package let streamID: StreamID
    package let reason: StopReason

    package enum StopReason: String, Codable {
        case clientRequested
        case windowClosed
        case error
    }

    package init(streamID: StreamID, reason: StopReason) {
        self.streamID = streamID
        self.reason = reason
    }
}

package struct StreamCaptureCadenceMetrics: Codable, Sendable, Equatable {
    package let wallClockGapWorstMs: Double
    package let wallClockGapP95Ms: Double
    package let wallClockGapP99Ms: Double
    package let presentationGapWorstMs: Double
    package let presentationGapP95Ms: Double
    package let presentationGapP99Ms: Double
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
    package let completeFrameStatusCount: UInt64
    package let idleFrameStatusCount: UInt64
    package let blankFrameStatusCount: UInt64
    package let suspendedFrameStatusCount: UInt64
    package let startedFrameStatusCount: UInt64
    package let stoppedFrameStatusCount: UInt64
    package let unknownFrameStatusCount: UInt64
    package let cadenceDropCount: UInt64
    package let admissionDropCount: UInt64
    package let sampleOverwriteCount: UInt64
    package let usesDisplayRefreshCadence: Bool?
    package let usesNativeRefreshMinimumFrameInterval: Bool?
    package let minimumFrameIntervalRate: Int?
    package let displayRefreshRate: Int?
    package let virtualDisplayID: UInt32?
    package let virtualDisplayRefreshRate: Double?
    package let virtualDisplayScaleFactor: Double?
    package let virtualDisplayGeneration: UInt64?
    package let virtualDisplayTimingSuspect: Bool?

    package init(
        wallClockGapWorstMs: Double = 0,
        wallClockGapP95Ms: Double = 0,
        wallClockGapP99Ms: Double = 0,
        presentationGapWorstMs: Double = 0,
        presentationGapP95Ms: Double = 0,
        presentationGapP99Ms: Double = 0,
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
        completeFrameStatusCount: UInt64 = 0,
        idleFrameStatusCount: UInt64 = 0,
        blankFrameStatusCount: UInt64 = 0,
        suspendedFrameStatusCount: UInt64 = 0,
        startedFrameStatusCount: UInt64 = 0,
        stoppedFrameStatusCount: UInt64 = 0,
        unknownFrameStatusCount: UInt64 = 0,
        cadenceDropCount: UInt64 = 0,
        admissionDropCount: UInt64 = 0,
        sampleOverwriteCount: UInt64 = 0,
        usesDisplayRefreshCadence: Bool? = nil,
        usesNativeRefreshMinimumFrameInterval: Bool? = nil,
        minimumFrameIntervalRate: Int? = nil,
        displayRefreshRate: Int? = nil,
        virtualDisplayID: UInt32? = nil,
        virtualDisplayRefreshRate: Double? = nil,
        virtualDisplayScaleFactor: Double? = nil,
        virtualDisplayGeneration: UInt64? = nil,
        virtualDisplayTimingSuspect: Bool? = nil
    ) {
        self.wallClockGapWorstMs = wallClockGapWorstMs
        self.wallClockGapP95Ms = wallClockGapP95Ms
        self.wallClockGapP99Ms = wallClockGapP99Ms
        self.presentationGapWorstMs = presentationGapWorstMs
        self.presentationGapP95Ms = presentationGapP95Ms
        self.presentationGapP99Ms = presentationGapP99Ms
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
        self.completeFrameStatusCount = completeFrameStatusCount
        self.idleFrameStatusCount = idleFrameStatusCount
        self.blankFrameStatusCount = blankFrameStatusCount
        self.suspendedFrameStatusCount = suspendedFrameStatusCount
        self.startedFrameStatusCount = startedFrameStatusCount
        self.stoppedFrameStatusCount = stoppedFrameStatusCount
        self.unknownFrameStatusCount = unknownFrameStatusCount
        self.cadenceDropCount = cadenceDropCount
        self.admissionDropCount = admissionDropCount
        self.sampleOverwriteCount = sampleOverwriteCount
        self.usesDisplayRefreshCadence = usesDisplayRefreshCadence
        self.usesNativeRefreshMinimumFrameInterval = usesNativeRefreshMinimumFrameInterval
        self.minimumFrameIntervalRate = minimumFrameIntervalRate
        self.displayRefreshRate = displayRefreshRate
        self.virtualDisplayID = virtualDisplayID
        self.virtualDisplayRefreshRate = virtualDisplayRefreshRate
        self.virtualDisplayScaleFactor = virtualDisplayScaleFactor
        self.virtualDisplayGeneration = virtualDisplayGeneration
        self.virtualDisplayTimingSuspect = virtualDisplayTimingSuspect
    }
}

/// Host-to-client stream metrics sampled per metrics-update window.
package struct StreamMetricsMessage: Codable, Sendable {
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
    package let captureIngressAverageMs: Double?
    package let captureIngressMaxMs: Double?
    package let preEncodeWaitAverageMs: Double?
    package let preEncodeWaitMaxMs: Double?
    package let captureCallbackAverageMs: Double?
    package let captureCallbackMaxMs: Double?
    package let captureCadence: StreamCaptureCadenceMetrics?
    package let sendQueueBytes: Int?
    package let sendStartDelayAverageMs: Double?
    package let sendStartDelayMaxMs: Double?
    package let sendCompletionAverageMs: Double?
    package let sendCompletionMaxMs: Double?
    package let nonKeyframeSendStartDelayAverageMs: Double?
    package let nonKeyframeSendStartDelayMaxMs: Double?
    package let nonKeyframeSendCompletionAverageMs: Double?
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
        captureIngressAverageMs: Double? = nil,
        captureIngressMaxMs: Double? = nil,
        preEncodeWaitAverageMs: Double? = nil,
        preEncodeWaitMaxMs: Double? = nil,
        captureCallbackAverageMs: Double? = nil,
        captureCallbackMaxMs: Double? = nil,
        captureCadence: StreamCaptureCadenceMetrics? = nil,
        sendQueueBytes: Int? = nil,
        sendStartDelayAverageMs: Double? = nil,
        sendStartDelayMaxMs: Double? = nil,
        sendCompletionAverageMs: Double? = nil,
        sendCompletionMaxMs: Double? = nil,
        nonKeyframeSendStartDelayAverageMs: Double? = nil,
        nonKeyframeSendStartDelayMaxMs: Double? = nil,
        nonKeyframeSendCompletionAverageMs: Double? = nil,
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
        self.captureIngressAverageMs = captureIngressAverageMs
        self.captureIngressMaxMs = captureIngressMaxMs
        self.preEncodeWaitAverageMs = preEncodeWaitAverageMs
        self.preEncodeWaitMaxMs = preEncodeWaitMaxMs
        self.captureCallbackAverageMs = captureCallbackAverageMs
        self.captureCallbackMaxMs = captureCallbackMaxMs
        self.captureCadence = captureCadence
        self.sendQueueBytes = sendQueueBytes
        self.sendStartDelayAverageMs = sendStartDelayAverageMs
        self.sendStartDelayMaxMs = sendStartDelayMaxMs
        self.sendCompletionAverageMs = sendCompletionAverageMs
        self.sendCompletionMaxMs = sendCompletionMaxMs
        self.nonKeyframeSendStartDelayAverageMs = nonKeyframeSendStartDelayAverageMs
        self.nonKeyframeSendStartDelayMaxMs = nonKeyframeSendStartDelayMaxMs
        self.nonKeyframeSendCompletionAverageMs = nonKeyframeSendCompletionAverageMs
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
