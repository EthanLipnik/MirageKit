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

/// Stream family used when reporting startup readiness.
package enum MirageStartupStreamKind: String, Codable {
    /// Single window stream.
    case window

    /// Desktop stream.
    case desktop

    /// Custom capture stream.
    case custom

    /// Shared app-atlas media stream.
    case appAtlas
}

/// Host-to-client full window inventory snapshot.
package struct WindowListMessage: Codable {
    /// Current visible windows available for streaming.
    package let windows: [MirageWindow]

    /// Creates a complete window inventory payload.
    package init(windows: [MirageWindow]) {
        self.windows = windows
    }
}

/// Host-to-client incremental window inventory update.
package struct WindowUpdateMessage: Codable {
    /// Windows newly available for streaming.
    package let added: [MirageWindow]

    /// Window IDs that are no longer available.
    package let removed: [WindowID]

    /// Existing windows with refreshed metadata.
    package let updated: [MirageWindow]
}

/// Client-to-host request to start streaming a single window.
package struct StartStreamMessage: Codable {
    /// Source window to stream.
    package let windowID: WindowID

    /// Client-selected target frame rate in Hz.
    package let targetFrameRate: Int

    /// Client display scale factor; when nil, the host uses its own scale factor.
    package var scaleFactor: CGFloat?

    /// Client logical display width in points for virtual-display sizing.
    package var displayWidth: Int?

    /// Client logical display height in points for virtual-display sizing.
    package var displayHeight: Int?

    /// Client-requested keyframe interval in frames.
    package var keyFrameInterval: Int?

    /// Client-requested ScreenCaptureKit queue depth.
    package var captureQueueDepth: Int?

    /// Client-requested stream color depth preset.
    package var colorDepth: MirageStreamColorDepth?

    /// Client-requested target bitrate in bits per second.
    package var bitrate: Int?

    /// Client-requested latency preference for host buffering and render behavior.
    package var latencyMode: MirageStreamLatencyMode?

    /// Client-requested runtime quality adaptation behavior on host.
    package var allowRuntimeQualityAdjustment: Bool?

    /// Client-requested compression boost for highest-resolution lowest-latency streams.
    package var lowLatencyHighResolutionCompressionBoost: Bool?

    /// Client-requested override to bypass host/client resolution caps.
    package var disableResolutionCap: Bool?

    /// Client-requested post-capture stream scale.
    package var streamScale: CGFloat?

    /// Client audio streaming configuration.
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

    /// Creates a window-stream startup request.
    package init(
        windowID: WindowID,
        targetFrameRate: Int,
        scaleFactor: CGFloat? = nil,
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
        mediaMaxPacketSize: Int? = nil,
        codec: MirageVideoCodec? = nil
    ) {
        self.windowID = windowID
        self.targetFrameRate = targetFrameRate
        self.scaleFactor = scaleFactor
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
        self.codec = codec
    }
}

/// Client-to-host request to stop a window stream.
package struct StopStreamMessage: Codable {
    /// Origin of the window-stream stop request.
    package enum Origin: String, Codable {
        /// The client-side stream window closed.
        case clientWindowClosed

        /// A remote command requested the stream stop.
        case remoteCommand
    }

    /// Stream to stop.
    package let streamID: StreamID

    /// Whether to minimize the source window on the host after stopping the stream.
    package var minimizeWindow: Bool = false

    /// Why the stop request was issued. Nil represents the default request path.
    package var origin: Origin?

    /// Creates a window-stream stop request.
    package init(streamID: StreamID, minimizeWindow: Bool = false, origin: Origin? = nil) {
        self.streamID = streamID
        self.minimizeWindow = minimizeWindow
        self.origin = origin
    }
}

/// Host-to-client confirmation that a window stream started.
package struct StreamStartedMessage: Codable {
    /// Stream ID assigned by the host.
    package let streamID: StreamID

    /// Source window ID.
    package let windowID: WindowID

    /// Encoded stream width in pixels.
    package let width: Int

    /// Encoded stream height in pixels.
    package let height: Int

    /// Stream frame rate in Hz.
    package let frameRate: Int

    /// Video codec selected by the host.
    package let codec: MirageVideoCodec

    /// Startup-attempt identifier used to gate first-frame readiness.
    package let startupAttemptID: UUID?

    /// Minimum window width in points; clients should not resize smaller.
    package var minWidth: Int?

    /// Minimum window height in points; clients should not resize smaller.
    package var minHeight: Int?

    /// Dimension token for rejecting old-dimension P-frames after resize.
    package var dimensionToken: UInt16?

    /// Media packet size accepted by the host for this stream.
    package var acceptedMediaMaxPacketSize: Int?

    /// Creates a window-stream started payload.
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

/// Host-to-client signal that the first frame path is ready for a startup attempt.
package struct StreamReadyMessage: Codable {
    /// Stream that became ready.
    package let streamID: StreamID

    /// Startup attempt this readiness signal belongs to.
    package let startupAttemptID: UUID

    /// Stream family that became ready.
    package let kind: MirageStartupStreamKind

    /// Creates a stream readiness signal.
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
