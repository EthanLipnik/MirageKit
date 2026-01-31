//
//  MessageTypes+Window.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation
import CoreGraphics

// MARK: - Window Messages

struct WindowListMessage: Codable {
    let windows: [MirageWindow]
}

struct WindowUpdateMessage: Codable {
    let added: [MirageWindow]
    let removed: [WindowID]
    let updated: [MirageWindow]
}

struct StartStreamMessage: Codable {
    let windowID: WindowID
    let preferredQuality: MirageQualityPreset
    /// UDP port the client is listening on for video data
    let dataPort: UInt16?
    /// Client's display scale factor (e.g., 2.0 for Retina Mac, ~1.72 for iPad Pro)
    /// If nil, host uses its own scale factor (backwards compatibility)
    var scaleFactor: CGFloat? = nil
    /// Client's requested pixel dimensions (optional, for initial stream setup)
    /// If nil, host uses window size × scaleFactor
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    /// Client's physical display resolution in pixels (for virtual display sizing)
    /// Virtual display will be created at this resolution
    var displayWidth: Int? = nil
    var displayHeight: Int? = nil
    /// Client-requested keyframe interval in frames
    /// Higher values (e.g., 600 = 10 seconds @ 60fps) reduce periodic lag spikes
    /// If nil, host uses default from encoder configuration
    var keyFrameInterval: Int? = nil
    /// Client-requested inter-frame quality (0.0-1.0)
    /// Lower values reduce frame size with minimal visual impact
    /// If nil, host uses default from encoder configuration
    var frameQuality: Float? = nil
    /// Client-requested keyframe quality (0.0-1.0)
    /// If nil, host uses default from encoder configuration
    var keyframeQuality: Float? = nil
    /// Client-requested pixel format (capture + encode)
    var pixelFormat: MiragePixelFormat? = nil
    /// Client-requested color space
    var colorSpace: MirageColorSpace? = nil
    /// Client-requested ScreenCaptureKit queue depth
    var captureQueueDepth: Int? = nil
    /// Client-requested minimum target bitrate (bits per second)
    var minBitrate: Int? = nil
    /// Client-requested maximum target bitrate (bits per second)
    var maxBitrate: Int? = nil
    /// Client-requested stream scale (0.1-1.0)
    /// Applies post-capture downscaling without resizing the host window
    var streamScale: CGFloat? = nil
    /// Client toggle for adaptive stream scaling (host may reduce streamScale to recover FPS)
    var adaptiveScaleEnabled: Bool? = nil
    /// Client latency preference for buffering behavior
    var latencyMode: MirageStreamLatencyMode? = nil
    /// Client refresh rate override in Hz (60/120 based on client capability).
    var maxRefreshRate: Int = 60
    /// Client audio mode selection (off/mono/stereo/surround/full)
    var audioMode: MirageAudioMode? = nil
    /// Client audio quality preset for AAC
    var audioQuality: MirageAudioQuality? = nil
    /// Client toggle to match audio quality to video preset
    var audioMatchVideoQuality: Bool? = nil
    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// Whether to stream in HDR (Rec. 2020 with PQ transfer function)
    // /// Requires HDR-capable display on both host and client
    // var preferHDR: Bool = false

    enum CodingKeys: String, CodingKey {
        case windowID
        case preferredQuality
        case dataPort
        case scaleFactor
        case pixelWidth
        case pixelHeight
        case displayWidth
        case displayHeight
        case keyFrameInterval
        case frameQuality = "keyframeQuality"
        case keyframeQuality = "keyframeQualityOverride"
        case pixelFormat
        case colorSpace
        case captureQueueDepth
        case minBitrate
        case maxBitrate
        case streamScale
        case adaptiveScaleEnabled
        case latencyMode
        case maxRefreshRate
        case audioMode
        case audioQuality
        case audioMatchVideoQuality
    }
}

struct StopStreamMessage: Codable {
    let streamID: StreamID
    /// Whether to minimize the source window on the host after stopping the stream
    var minimizeWindow: Bool = false
}

struct StreamStartedMessage: Codable {
    let streamID: StreamID
    let windowID: WindowID
    let width: Int
    let height: Int
    let frameRate: Int
    let codec: MirageVideoCodec
    /// Minimum window size in points - client should not resize smaller
    var minWidth: Int? = nil
    var minHeight: Int? = nil
    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Client should update its reassembler with this token.
    var dimensionToken: UInt16? = nil
}

struct StreamStoppedMessage: Codable {
    let streamID: StreamID
    let reason: StopReason

    enum StopReason: String, Codable {
        case clientRequested
        case windowClosed
        case error
    }
}

struct StreamMetricsMessage: Codable, Sendable {
    let streamID: StreamID
    let encodedFPS: Double
    let idleEncodedFPS: Double
    let droppedFrames: UInt64
    let activeQuality: Float
    let targetFrameRate: Int
}
