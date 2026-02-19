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
    /// If nil, host uses its own scale factor (backwards compatibility)
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
    /// Client-requested stream bit depth.
    package var bitDepth: MirageVideoBitDepth?
    /// Client-requested target bitrate (bits per second)
    package var bitrate: Int?
    /// Client-requested latency preference for host buffering and render behavior.
    package var latencyMode: MirageStreamLatencyMode?
    /// Client-requested runtime quality adaptation behavior on host.
    package var allowRuntimeQualityAdjustment: Bool?
    /// Client-requested override to bypass host/client resolution caps.
    package var disableResolutionCap: Bool?
    /// Client-requested stream scale (0.1-1.0)
    /// Applies post-capture downscaling without resizing the host window
    package var streamScale: CGFloat?
    /// Client audio streaming configuration
    package var audioConfiguration: MirageAudioConfiguration?
    /// Client refresh rate override in Hz (60/120 based on client capability).
    package var maxRefreshRate: Int = 60
    // TODO: HDR support - requires proper virtual display EDR configuration
    // /// Whether to stream in HDR (Rec. 2020 with PQ transfer function)
    // /// Requires HDR-capable display on both host and client
    // var preferHDR: Bool = false

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
        case bitDepth
        case bitrate
        case latencyMode
        case allowRuntimeQualityAdjustment
        case disableResolutionCap
        case streamScale
        case audioConfiguration
        case maxRefreshRate
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
        bitDepth: MirageVideoBitDepth? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
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
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.latencyMode = latencyMode
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.disableResolutionCap = disableResolutionCap
        self.streamScale = streamScale
        self.audioConfiguration = audioConfiguration
        self.maxRefreshRate = maxRefreshRate
    }
}

package struct StopStreamMessage: Codable {
    package let streamID: StreamID
    /// Whether to minimize the source window on the host after stopping the stream
    package var minimizeWindow: Bool = false

    package init(streamID: StreamID, minimizeWindow: Bool = false) {
        self.streamID = streamID
        self.minimizeWindow = minimizeWindow
    }
}

package struct StreamStartedMessage: Codable {
    package let streamID: StreamID
    package let windowID: WindowID
    package let width: Int
    package let height: Int
    package let frameRate: Int
    package let codec: MirageVideoCodec
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
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.dimensionToken = dimensionToken
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
    package let capturePixelFormat: String?
    package let captureColorPrimaries: String?
    package let encoderPixelFormat: String?
    package let encoderProfile: String?
    package let encoderColorPrimaries: String?
    package let encoderTransferFunction: String?
    package let encoderYCbCrMatrix: String?
    package let tenBitDisplayP3Validated: Bool?

    package init(
        streamID: StreamID,
        encodedFPS: Double,
        idleEncodedFPS: Double,
        droppedFrames: UInt64,
        activeQuality: Float,
        targetFrameRate: Int,
        capturePixelFormat: String? = nil,
        captureColorPrimaries: String? = nil,
        encoderPixelFormat: String? = nil,
        encoderProfile: String? = nil,
        encoderColorPrimaries: String? = nil,
        encoderTransferFunction: String? = nil,
        encoderYCbCrMatrix: String? = nil,
        tenBitDisplayP3Validated: Bool? = nil
    ) {
        self.streamID = streamID
        self.encodedFPS = encodedFPS
        self.idleEncodedFPS = idleEncodedFPS
        self.droppedFrames = droppedFrames
        self.activeQuality = activeQuality
        self.targetFrameRate = targetFrameRate
        self.capturePixelFormat = capturePixelFormat
        self.captureColorPrimaries = captureColorPrimaries
        self.encoderPixelFormat = encoderPixelFormat
        self.encoderProfile = encoderProfile
        self.encoderColorPrimaries = encoderColorPrimaries
        self.encoderTransferFunction = encoderTransferFunction
        self.encoderYCbCrMatrix = encoderYCbCrMatrix
        self.tenBitDisplayP3Validated = tenBitDisplayP3Validated
    }
}
