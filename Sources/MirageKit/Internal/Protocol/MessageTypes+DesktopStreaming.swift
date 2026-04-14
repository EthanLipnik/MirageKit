//
//  MessageTypes+DesktopStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import CoreGraphics
import Foundation

// MARK: - Desktop Streaming Messages

/// Request to start streaming the desktop (Client → Host)
/// This can stream the unified desktop or run as a secondary display
package struct StartDesktopStreamMessage: Codable {
    /// Client's display scale factor
    package let scaleFactor: CGFloat?
    /// Client's display width in points (logical view bounds)
    package let displayWidth: Int
    /// Client's display height in points (logical view bounds)
    package let displayHeight: Int
    /// Client-selected target frame rate in Hz.
    package let targetFrameRate: Int
    /// Client-requested keyframe interval in frames
    package var keyFrameInterval: Int?
    /// Client-requested ScreenCaptureKit queue depth
    package var captureQueueDepth: Int?
    /// Client-requested stream color depth preset.
    package var colorDepth: MirageStreamColorDepth?
    /// Desktop stream mode (unified vs secondary display)
    package var mode: MirageDesktopStreamMode?
    /// Desktop cursor presentation requested by the client.
    package var cursorPresentation: MirageDesktopCursorPresentation?
    /// Client-entered bitrate budget before any desktop geometry scaling.
    package var enteredBitrate: Int?
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
    /// Client-requested override to bypass host/client resolution caps.
    package var disableResolutionCap: Bool?
    /// Client-requested stream scale (0.1-1.0)
    package let streamScale: CGFloat?
    /// Client audio streaming configuration
    package let audioConfiguration: MirageAudioConfiguration?
    /// UDP port the client is listening on for video data
    package let dataPort: UInt16?
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
    /// When true, the host should use its current display resolution instead of the client-provided dimensions.
    package var useHostResolution: Bool?

    enum CodingKeys: String, CodingKey {
        case scaleFactor
        case displayWidth
        case displayHeight
        case targetFrameRate
        case keyFrameInterval
        case captureQueueDepth
        case colorDepth
        case mode
        case cursorPresentation
        case enteredBitrate
        case bitrate
        case latencyMode
        case performanceMode
        case allowRuntimeQualityAdjustment
        case lowLatencyHighResolutionCompressionBoost
        case disableResolutionCap
        case streamScale
        case audioConfiguration
        case dataPort
        case bitrateAdaptationCeiling
        case encoderMaxWidth
        case encoderMaxHeight
        case mediaMaxPacketSize
        case upscalingMode
        case codec
        case useHostResolution
    }

    package init(
        scaleFactor: CGFloat?,
        displayWidth: Int,
        displayHeight: Int,
        targetFrameRate: Int,
        keyFrameInterval: Int? = nil,
        captureQueueDepth: Int? = nil,
        colorDepth: MirageStreamColorDepth? = nil,
        mode: MirageDesktopStreamMode? = nil,
        cursorPresentation: MirageDesktopCursorPresentation? = nil,
        enteredBitrate: Int? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        performanceMode: MirageStreamPerformanceMode? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        disableResolutionCap: Bool? = nil,
        streamScale: CGFloat? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        dataPort: UInt16? = nil,
        useHostResolution: Bool? = nil,
        mediaMaxPacketSize: Int? = nil
    ) {
        self.scaleFactor = scaleFactor
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.captureQueueDepth = captureQueueDepth
        self.colorDepth = colorDepth
        self.mode = mode
        self.cursorPresentation = cursorPresentation
        self.enteredBitrate = enteredBitrate
        self.bitrate = bitrate
        self.latencyMode = latencyMode
        self.performanceMode = performanceMode
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        self.disableResolutionCap = disableResolutionCap
        self.streamScale = streamScale
        self.audioConfiguration = audioConfiguration
        self.dataPort = dataPort
        self.useHostResolution = useHostResolution
        self.mediaMaxPacketSize = mediaMaxPacketSize
    }
}

/// Runtime desktop cursor presentation update (Client → Host).
package struct DesktopCursorPresentationChangeMessage: Codable {
    package let streamID: StreamID
    package let cursorPresentation: MirageDesktopCursorPresentation

    package init(
        streamID: StreamID,
        cursorPresentation: MirageDesktopCursorPresentation
    ) {
        self.streamID = streamID
        self.cursorPresentation = cursorPresentation
    }
}

/// Request to stop the desktop stream (Client → Host)
package struct StopDesktopStreamMessage: Codable {
    /// The desktop stream ID to stop
    package let streamID: StreamID

    package init(streamID: StreamID) {
        self.streamID = streamID
    }
}

/// Client → Host: Cancel any in-progress stream setup (desktop or app).
/// Sent when the user cancels during the loading phase before a stream ID is established.
package struct CancelStreamSetupMessage: Codable {
    package init() {}
}

package enum MirageDesktopTransitionPhase: String, Codable, Sendable {
    case startup
    case resize
}

package enum MirageDesktopTransitionOutcome: String, Codable, Sendable {
    case noChange
    case resized
    case rolledBack
}

/// Confirmation that desktop streaming has started (Host → Client)
package struct DesktopStreamStartedMessage: Codable {
    /// Stream ID for the desktop stream
    package let streamID: StreamID
    /// Resolution of the virtual display
    package let width: Int
    package let height: Int
    /// Frame rate of the stream
    package let frameRate: Int
    /// Video codec being used
    package let codec: MirageVideoCodec
    /// Startup-attempt identifier used to gate first-frame readiness.
    package let startupAttemptID: UUID?
    /// Number of physical displays being mirrored
    package let displayCount: Int
    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Client should update its reassembler with this token.
    package var dimensionToken: UInt16?
    /// Media packet size accepted by the host for this stream.
    package var acceptedMediaMaxPacketSize: Int?
    /// Optional transition identifier for resize commits.
    package var transitionID: UUID?
    /// Whether this packet describes initial startup or a live resize transition.
    package var transitionPhase: MirageDesktopTransitionPhase?
    /// Optional resize outcome metadata.
    package var transitionOutcome: MirageDesktopTransitionOutcome?

    package init(
        streamID: StreamID,
        width: Int,
        height: Int,
        frameRate: Int,
        codec: MirageVideoCodec,
        startupAttemptID: UUID? = nil,
        displayCount: Int,
        dimensionToken: UInt16? = nil,
        acceptedMediaMaxPacketSize: Int? = nil,
        transitionID: UUID? = nil,
        transitionPhase: MirageDesktopTransitionPhase? = nil,
        transitionOutcome: MirageDesktopTransitionOutcome? = nil
    ) {
        self.streamID = streamID
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.startupAttemptID = startupAttemptID
        self.displayCount = displayCount
        self.dimensionToken = dimensionToken
        self.acceptedMediaMaxPacketSize = acceptedMediaMaxPacketSize
        self.transitionID = transitionID
        self.transitionPhase = transitionPhase
        self.transitionOutcome = transitionOutcome
    }
}

/// Desktop stream stopped notification (Host → Client)
package struct DesktopStreamStoppedMessage: Codable {
    /// The stream ID that was stopped
    package let streamID: StreamID
    /// Why the stream was stopped
    package let reason: DesktopStreamStopReason

    package init(streamID: StreamID, reason: DesktopStreamStopReason) {
        self.streamID = streamID
        self.reason = reason
    }
}

/// Desktop stream start failed notification (Host → Client)
package struct DesktopStreamFailedMessage: Codable {
    /// Human-readable reason the stream failed to start
    package let reason: String
    /// Error classification for client-side disposition
    package let errorCode: ErrorMessage.ErrorCode

    package init(reason: String, errorCode: ErrorMessage.ErrorCode) {
        self.reason = reason
        self.errorCode = errorCode
    }
}

/// Reasons why a desktop stream was stopped
public enum DesktopStreamStopReason: String, Codable, Sendable {
    /// Client requested the stop
    case clientRequested
    /// User started an app stream (mutual exclusivity)
    case appStreamStarted
    /// Host shut down or disconnected
    case hostShutdown
    /// An error occurred
    case error
}
