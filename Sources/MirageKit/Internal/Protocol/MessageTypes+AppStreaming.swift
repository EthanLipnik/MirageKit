//
//  MessageTypes+AppStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - App-Centric Streaming Messages

/// Runtime priority tier assigned to an active media stream.
public enum MirageStreamRuntimeTier: String, Codable, Sendable {
    /// Stream should encode live frames at the requested cadence.
    case activeLive

    /// Stream may run at a lower snapshot cadence.
    case passiveSnapshot
}

/// Host runtime policy for one media stream.
public struct MirageStreamPolicy: Codable, Sendable, Equatable {
    /// Stream receiving the policy.
    public let streamID: StreamID

    /// Runtime tier to apply.
    public let tier: MirageStreamRuntimeTier

    /// Target frame rate after clamping.
    public let targetFPS: Int

    /// Target bitrate in bits per second, when constrained.
    public let targetBitrateBps: Int?

    /// Creates a clamped stream runtime policy.
    package init(
        streamID: StreamID,
        tier: MirageStreamRuntimeTier,
        targetFPS: Int,
        targetBitrateBps: Int?
    ) {
        self.streamID = streamID
        self.tier = tier
        self.targetFPS = max(1, min(120, targetFPS))
        self.targetBitrateBps = targetBitrateBps
    }
}

/// Batch of stream runtime policies for an app-stream epoch.
public struct StreamPolicyUpdateMessage: Codable, Sendable, Equatable {
    /// Monotonic policy epoch.
    public let epoch: UInt64

    /// Policies sorted by stream ID for deterministic encoding.
    public let policies: [MirageStreamPolicy]

    /// Creates a deterministic policy update payload.
    package init(epoch: UInt64, policies: [MirageStreamPolicy]) {
        self.epoch = epoch
        self.policies = policies.sorted { lhs, rhs in
            lhs.streamID < rhs.streamID
        }
    }
}

/// Host-to-client media-stream update for an app atlas.
public struct AppAtlasMediaUpdateMessage: Codable, Sendable, Equatable {
    /// Physical media stream carrying atlas regions.
    public let mediaStreamID: StreamID

    /// Encoded atlas width in pixels.
    public let width: Int

    /// Encoded atlas height in pixels.
    public let height: Int

    /// Video codec selected for the media stream.
    public let codec: MirageVideoCodec

    /// Frame rate selected for the media stream.
    public let frameRate: Int

    /// Dimension token for rejecting stale packets after layout or size changes.
    public let dimensionToken: UInt16?

    /// Layout epoch represented by `layout`.
    public let layoutEpoch: UInt64

    /// Accepted media packet size for the stream.
    public let acceptedPacketSize: Int?

    /// Atlas layout describing logical app-window regions.
    public let layout: MirageAppAtlasLayout

    /// Startup attempt associated with the atlas media stream.
    public let startupAttemptID: UUID

    /// Creates an app-atlas media update payload.
    package init(
        mediaStreamID: StreamID,
        width: Int,
        height: Int,
        codec: MirageVideoCodec,
        frameRate: Int,
        dimensionToken: UInt16? = nil,
        layoutEpoch: UInt64,
        acceptedPacketSize: Int? = nil,
        layout: MirageAppAtlasLayout,
        startupAttemptID: UUID
    ) {
        self.mediaStreamID = mediaStreamID
        self.width = width
        self.height = height
        self.codec = codec
        self.frameRate = frameRate
        self.dimensionToken = dimensionToken
        self.layoutEpoch = layoutEpoch
        self.acceptedPacketSize = acceptedPacketSize
        self.layout = layout
        self.startupAttemptID = startupAttemptID
    }
}

/// Client-to-host request to start app streaming.
package struct SelectAppMessage: Codable {
    /// Request-scoped identifier used to cancel or reject stale startup work.
    package let startupRequestID: UUID

    /// Host/client app-session identifier for this app-stream startup.
    package let appSessionID: UUID

    /// Bundle identifier of the app to stream.
    package let bundleIdentifier: String

    /// Client-selected target frame rate in Hz.
    package let targetFrameRate: Int

    /// Client display scale factor.
    package let scaleFactor: CGFloat?

    /// Client display width in points.
    package let displayWidth: Int?

    /// Client display height in points.
    package let displayHeight: Int?

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

    /// Client-requested host-side capture-to-encode buffering policy.
    package var hostBufferingPolicy: MirageHostBufferingPolicy?

    /// Client-requested runtime quality adaptation behavior on host.
    package var allowRuntimeQualityAdjustment: Bool?

    /// Client-requested compression boost for highest-resolution lowest-latency streams.
    package var lowLatencyHighResolutionCompressionBoost: Bool?

    /// Client-requested override to bypass host/client resolution caps.
    package var disableResolutionCap: Bool?

    /// Client audio streaming configuration.
    package let audioConfiguration: MirageAudioConfiguration?

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

    /// Maximum concurrent visible app windows requested by the client tier policy.
    package let maxConcurrentVisibleWindows: Int

    /// Client-requested shared bitrate allocation policy for multi-window app streaming.
    package let bitrateAllocationPolicy: MirageAppStreamBitrateAllocationPolicy?

    /// Client-requested virtual display size preset for app streaming.
    package var sizePreset: MirageDisplaySizePreset?

    /// Creates an app-stream startup request.
    package init(
        startupRequestID: UUID = UUID(),
        appSessionID: UUID = UUID(),
        bundleIdentifier: String,
        targetFrameRate: Int,
        scaleFactor: CGFloat? = nil,
        displayWidth: Int? = nil,
        displayHeight: Int? = nil,
        keyFrameInterval: Int? = nil,
        captureQueueDepth: Int? = nil,
        colorDepth: MirageStreamColorDepth? = nil,
        bitrate: Int? = nil,
        latencyMode: MirageStreamLatencyMode? = nil,
        hostBufferingPolicy: MirageHostBufferingPolicy? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        disableResolutionCap: Bool? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        maxConcurrentVisibleWindows: Int = 1,
        bitrateAllocationPolicy: MirageAppStreamBitrateAllocationPolicy? = nil,
        sizePreset: MirageDisplaySizePreset? = nil,
        mediaMaxPacketSize: Int? = nil,
        codec: MirageVideoCodec? = nil
    ) {
        self.startupRequestID = startupRequestID
        self.appSessionID = appSessionID
        self.bundleIdentifier = bundleIdentifier
        self.targetFrameRate = targetFrameRate
        self.scaleFactor = scaleFactor
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.keyFrameInterval = keyFrameInterval
        self.captureQueueDepth = captureQueueDepth
        self.colorDepth = colorDepth
        self.bitrate = bitrate
        self.latencyMode = latencyMode
        self.hostBufferingPolicy = hostBufferingPolicy
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        self.disableResolutionCap = disableResolutionCap
        self.audioConfiguration = audioConfiguration
        self.maxConcurrentVisibleWindows = max(1, maxConcurrentVisibleWindows)
        self.bitrateAllocationPolicy = bitrateAllocationPolicy
        self.sizePreset = sizePreset
        self.mediaMaxPacketSize = mediaMaxPacketSize
        self.codec = codec
    }

    package var resolvedHostBufferingPolicy: MirageHostBufferingPolicy {
        hostBufferingPolicy ?? .stability
    }
}

/// Host-to-client confirmation that app streaming has started.
public struct AppStreamStartedMessage: Codable, Sendable {
    /// Stable app-session identifier for this app stream.
    public let appSessionID: UUID
    /// Startup request that produced this app session.
    public let startupRequestID: UUID?
    /// Bundle identifier of the app being streamed
    public let bundleIdentifier: String
    /// App display name
    public let appName: String
    /// Initial windows that are now streaming
    public let windows: [AppStreamWindow]
    /// Optional atlas layouts for physical media streams carrying logical app-window regions.
    public let atlasLayouts: [MirageAppAtlasLayout]?

    /// Logical app window included in an app-stream session.
    public struct AppStreamWindow: Codable, Sendable {
        /// Logical stream ID for routing input and lifecycle events.
        public let streamID: StreamID

        /// Physical media stream carrying this window.
        public let mediaStreamID: StreamID

        /// Host window ID.
        public let windowID: WindowID

        /// Host window title, when available.
        public let title: String?

        /// Calibrated stream viewport width in points (derived from dedicated virtual-display visible frame).
        public let width: Int

        /// Calibrated stream viewport height in points (derived from dedicated virtual-display visible frame).
        public let height: Int

        /// Whether the source window can be resized by Mirage.
        public let isResizable: Bool

        /// Atlas region carrying this logical window, if atlas media is used.
        public let atlasRegion: MirageAppAtlasRegion?

        /// Creates a logical app-stream window descriptor.
        package init(
            streamID: StreamID,
            mediaStreamID: StreamID,
            windowID: WindowID,
            title: String?,
            width: Int,
            height: Int,
            isResizable: Bool,
            atlasRegion: MirageAppAtlasRegion? = nil
        ) {
            self.streamID = streamID
            self.mediaStreamID = mediaStreamID
            self.windowID = windowID
            self.title = title
            self.width = width
            self.height = height
            self.isResizable = isResizable
            self.atlasRegion = atlasRegion
        }
    }

    /// Creates an app-stream started payload.
    package init(
        appSessionID: UUID,
        startupRequestID: UUID?,
        bundleIdentifier: String,
        appName: String,
        windows: [AppStreamWindow],
        atlasLayouts: [MirageAppAtlasLayout]? = nil
    ) {
        self.appSessionID = appSessionID
        self.startupRequestID = startupRequestID
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windows = windows
        self.atlasLayouts = atlasLayouts
    }
}
