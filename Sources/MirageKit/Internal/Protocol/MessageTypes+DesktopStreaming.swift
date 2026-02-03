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
struct StartDesktopStreamMessage: Codable {
    /// Client's display scale factor
    let scaleFactor: CGFloat?
    /// Client's display width in pixels
    let displayWidth: Int
    /// Client's display height in pixels
    let displayHeight: Int
    /// Client-requested keyframe interval in frames
    var keyFrameInterval: Int?
    /// Client-requested pixel format (capture + encode)
    var pixelFormat: MiragePixelFormat?
    /// Client-requested color space
    var colorSpace: MirageColorSpace?
    /// Client-requested ScreenCaptureKit queue depth
    var captureQueueDepth: Int?
    /// Desktop stream mode (mirrored vs secondary display)
    var mode: MirageDesktopStreamMode?
    /// Client-requested minimum target bitrate (bits per second)
    var minBitrate: Int?
    /// Client-requested maximum target bitrate (bits per second)
    var maxBitrate: Int?
    /// Client-requested stream scale (0.1-1.0)
    let streamScale: CGFloat?
    /// Client latency preference for buffering behavior
    let latencyMode: MirageStreamLatencyMode?
    /// UDP port the client is listening on for video data
    let dataPort: UInt16?
    /// Client refresh rate override in Hz (60/120 based on client capability)
    /// Used with P2P detection to enable 120fps streaming on capable displays
    let maxRefreshRate: Int
    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// Whether to stream in HDR (Rec. 2020 with PQ transfer function)
    // var preferHDR: Bool = false

    enum CodingKeys: String, CodingKey {
        case scaleFactor
        case displayWidth
        case displayHeight
        case keyFrameInterval
        case pixelFormat
        case colorSpace
        case captureQueueDepth
        case mode
        case minBitrate
        case maxBitrate
        case streamScale
        case latencyMode
        case dataPort
        case maxRefreshRate
    }
}

/// Request to stop the desktop stream (Client → Host)
struct StopDesktopStreamMessage: Codable {
    /// The desktop stream ID to stop
    let streamID: StreamID
}

/// Confirmation that desktop streaming has started (Host → Client)
struct DesktopStreamStartedMessage: Codable {
    /// Stream ID for the desktop stream
    let streamID: StreamID
    /// Resolution of the virtual display
    let width: Int
    let height: Int
    /// Frame rate of the stream
    let frameRate: Int
    /// Video codec being used
    let codec: MirageVideoCodec
    /// Number of physical displays being mirrored
    let displayCount: Int
    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Client should update its reassembler with this token.
    var dimensionToken: UInt16?
}

/// Desktop stream stopped notification (Host → Client)
struct DesktopStreamStoppedMessage: Codable {
    /// The stream ID that was stopped
    let streamID: StreamID
    /// Why the stream was stopped
    let reason: DesktopStreamStopReason
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
