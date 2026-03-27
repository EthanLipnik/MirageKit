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
    /// Client-requested host performance profile.
    package var performanceMode: MirageStreamPerformanceMode?
    /// Client-requested runtime quality adaptation behavior on host.
    package var allowRuntimeQualityAdjustment: Bool?
    /// Client-requested compression boost for highest-resolution lowest-latency streams.
    package var lowLatencyHighResolutionCompressionBoost: Bool?
    /// Client-requested temporary degradation policy.
    package var temporaryDegradationMode: MirageTemporaryDegradationMode?
    /// Client-requested override to bypass host/client resolution caps.
    package var disableResolutionCap: Bool?
    /// Client-requested stream scale (0.1-1.0)
    /// Applies post-capture downscaling without resizing the host window
    package var streamScale: CGFloat?
    /// Client audio streaming configuration
    package var audioConfiguration: MirageAudioConfiguration?
    /// Client refresh rate override in Hz (60/120 based on client capability).
    package var maxRefreshRate: Int = 60
    /// Maximum bitrate the in-stream adaptation governor may ramp toward.
    package var bitrateAdaptationCeiling: Int?
    /// Maximum encoded width in pixels for host-computed stream scaling.
    package var encoderMaxWidth: Int?
    /// Maximum encoded height in pixels for host-computed stream scaling.
    package var encoderMaxHeight: Int?
    /// Client-requested MetalFX upscaling mode.
    package var upscalingMode: MirageUpscalingMode?
    /// Client-requested video codec.
    package var codec: MirageVideoCodec?

    enum CodingKeys: String, CodingKey {
        case windowID
        case dataPort
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
        case performanceMode
        case allowRuntimeQualityAdjustment
        case lowLatencyHighResolutionCompressionBoost
        case temporaryDegradationMode
        case disableResolutionCap
        case streamScale
        case audioConfiguration
        case maxRefreshRate
        case bitrateAdaptationCeiling
        case encoderMaxWidth
        case encoderMaxHeight
        case upscalingMode
        case codec
    }

    package init(
        windowID: WindowID,
        dataPort: UInt16? = nil,
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
        performanceMode: MirageStreamPerformanceMode? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        temporaryDegradationMode: MirageTemporaryDegradationMode? = nil,
        disableResolutionCap: Bool? = nil,
        streamScale: CGFloat? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        maxRefreshRate: Int = 60
    ) {
        self.windowID = windowID
        self.dataPort = dataPort
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
        self.performanceMode = performanceMode
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        self.temporaryDegradationMode = temporaryDegradationMode
        self.disableResolutionCap = disableResolutionCap
        self.streamScale = streamScale
        self.audioConfiguration = audioConfiguration
        self.maxRefreshRate = maxRefreshRate
    }
}

package struct StopStreamMessage: Codable {
    package enum Origin: String, Codable, Sendable {
        case clientWindowClosed
    }

    package let streamID: StreamID
    /// Whether to minimize the source window on the host after stopping the stream
    package var minimizeWindow: Bool = false
    /// Why the stop request was issued. Nil represents legacy/default request paths.
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
        dimensionToken: UInt16? = nil
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

package struct StreamMetricsMessage: Codable, Sendable {
    package let streamID: StreamID
    package let encodedFPS: Double
    package let idleEncodedFPS: Double
    package let droppedFrames: UInt64
    package let activeQuality: Float
    package let targetFrameRate: Int
    package let currentBitrate: Int?
    package let requestedTargetBitrate: Int?
    package let startupBitrate: Int?
    package let temporaryDegradationMode: MirageTemporaryDegradationMode?
    package let temporaryDegradationColorDepth: MirageStreamColorDepth?
    package let timeBelowTargetBitrateMs: Int?
    package let captureAdmissionDrops: UInt64?
    package let frameBudgetMs: Double?
    package let averageEncodeMs: Double?
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
        currentBitrate: Int? = nil,
        requestedTargetBitrate: Int? = nil,
        startupBitrate: Int? = nil,
        temporaryDegradationMode: MirageTemporaryDegradationMode? = nil,
        temporaryDegradationColorDepth: MirageStreamColorDepth? = nil,
        timeBelowTargetBitrateMs: Int? = nil,
        captureAdmissionDrops: UInt64? = nil,
        frameBudgetMs: Double? = nil,
        averageEncodeMs: Double? = nil,
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
        self.currentBitrate = currentBitrate
        self.requestedTargetBitrate = requestedTargetBitrate
        self.startupBitrate = startupBitrate
        self.temporaryDegradationMode = temporaryDegradationMode
        self.temporaryDegradationColorDepth = temporaryDegradationColorDepth
        self.timeBelowTargetBitrateMs = timeBelowTargetBitrateMs
        self.captureAdmissionDrops = captureAdmissionDrops
        self.frameBudgetMs = frameBudgetMs
        self.averageEncodeMs = averageEncodeMs
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
