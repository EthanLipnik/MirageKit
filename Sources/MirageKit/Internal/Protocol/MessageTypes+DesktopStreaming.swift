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
/// This can mirror all physical displays or run as a secondary display
package struct StartDesktopStreamMessage: Codable {
    /// Client's display scale factor
    package let scaleFactor: CGFloat?
    /// Client's display width in points (logical view bounds)
    package let displayWidth: Int
    /// Client's display height in points (logical view bounds)
    package let displayHeight: Int
    /// Client-requested keyframe interval in frames
    package var keyFrameInterval: Int?
    /// Client-requested ScreenCaptureKit queue depth
    package var captureQueueDepth: Int?
    /// Client-requested stream bit depth.
    package var bitDepth: MirageVideoBitDepth?
    /// Desktop stream mode (mirrored vs secondary display)
    package var mode: MirageDesktopStreamMode?
    /// Client-requested target bitrate (bits per second)
    package var bitrate: Int?
    /// Client-requested runtime quality adaptation behavior on host.
    package var allowRuntimeQualityAdjustment: Bool?
    /// Client-requested override to bypass host/client resolution caps.
    package var disableResolutionCap: Bool?
    /// Client-requested stream scale (0.1-1.0)
    package let streamScale: CGFloat?
    /// Client latency preference for buffering behavior
    package let latencyMode: MirageStreamLatencyMode?
    /// Client audio streaming configuration
    package let audioConfiguration: MirageAudioConfiguration?
    /// UDP port the client is listening on for video data
    package let dataPort: UInt16?
    /// Client refresh rate override in Hz (60/120 based on client capability)
    /// Used with P2P detection to enable 120fps streaming on capable displays
    package let maxRefreshRate: Int
    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// Whether to stream in HDR (Rec. 2020 with PQ transfer function)
    // var preferHDR: Bool = false

    enum CodingKeys: String, CodingKey {
        case scaleFactor
        case displayWidth
        case displayHeight
        case keyFrameInterval
        case captureQueueDepth
        case bitDepth
        case mode
        case bitrate
        case allowRuntimeQualityAdjustment
        case disableResolutionCap
        case streamScale
        case latencyMode
        case audioConfiguration
        case dataPort
        case maxRefreshRate
    }

    package init(
        scaleFactor: CGFloat?,
        displayWidth: Int,
        displayHeight: Int,
        keyFrameInterval: Int? = nil,
        captureQueueDepth: Int? = nil,
        bitDepth: MirageVideoBitDepth? = nil,
        mode: MirageDesktopStreamMode? = nil,
        bitrate: Int? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        disableResolutionCap: Bool? = nil,
        streamScale: CGFloat? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        dataPort: UInt16? = nil,
        maxRefreshRate: Int
    ) {
        self.scaleFactor = scaleFactor
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.keyFrameInterval = keyFrameInterval
        self.captureQueueDepth = captureQueueDepth
        self.bitDepth = bitDepth
        self.mode = mode
        self.bitrate = bitrate
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.disableResolutionCap = disableResolutionCap
        self.streamScale = streamScale
        self.latencyMode = latencyMode
        self.audioConfiguration = audioConfiguration
        self.dataPort = dataPort
        self.maxRefreshRate = maxRefreshRate
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
    /// Number of physical displays being mirrored
    package let displayCount: Int
    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Client should update its reassembler with this token.
    package var dimensionToken: UInt16?

    package init(
        streamID: StreamID,
        width: Int,
        height: Int,
        frameRate: Int,
        codec: MirageVideoCodec,
        displayCount: Int,
        dimensionToken: UInt16? = nil
    ) {
        self.streamID = streamID
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.displayCount = displayCount
        self.dimensionToken = dimensionToken
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
