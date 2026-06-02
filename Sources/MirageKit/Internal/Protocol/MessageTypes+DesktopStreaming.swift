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

/// Stream setup family used to scope cancellation and startup handling.
package enum StreamSetupKind: String, Codable {
    /// App-window stream setup.
    case app

    /// Desktop stream setup.
    case desktop

    /// Custom stream setup.
    case custom
}

/// Client-to-host request to start a desktop stream.
///
/// The request can start unified desktop mirroring or a secondary virtual display.
package struct StartDesktopStreamMessage: Codable {
    /// Request-scoped identifier used to cancel or reject stale startup work.
    package let startupRequestID: UUID

    /// Client display scale factor.
    package let scaleFactor: CGFloat?

    /// Client display width in points.
    package let displayWidth: Int

    /// Client display height in points.
    package let displayHeight: Int

    /// Client-selected target frame rate in Hz.
    package let targetFrameRate: Int

    /// Client-requested keyframe interval in frames.
    package var keyFrameInterval: Int?

    /// Client-requested ScreenCaptureKit queue depth.
    package var captureQueueDepth: Int?

    /// Client-requested stream color depth preset.
    package var colorDepth: MirageStreamColorDepth?

    /// Desktop stream mode.
    package var mode: MirageDesktopStreamMode?

    /// Desktop cursor presentation requested by the client.
    package var cursorPresentation: MirageDesktopCursorPresentation?

    /// Client-entered bitrate budget before any desktop geometry scaling.
    package var enteredBitrate: Int?

    /// Client-requested target bitrate in bits per second.
    package var bitrate: Int?

    /// Client-requested latency preference for host buffering and render behavior.
    package var latencyMode: MirageStreamLatencyMode?

    /// Client-requested host-side capture-to-encode buffering policy.
    package var hostBufferingPolicy: MirageHostBufferingPolicy?

    /// Client-requested runtime quality adaptation behavior on host.
    package var allowRuntimeQualityAdjustment: Bool?

    /// Client-requested quality reduction when host encoding falls behind.
    package var allowEncoderCatchUpQualityAdjustment: Bool?

    /// Client-requested compression boost for highest-resolution lowest-latency streams.
    package var lowLatencyHighResolutionCompressionBoost: Bool?

    /// Client-requested override to bypass host/client resolution caps.
    package var disableResolutionCap: Bool?

    /// Client-requested post-capture stream scale.
    package let streamScale: CGFloat?

    /// Client audio streaming configuration.
    package let audioConfiguration: MirageAudioConfiguration?

    /// UDP port the client is listening on for video data.
    package let dataPort: UInt16?

    /// Maximum bitrate the in-stream adaptation governor may ramp toward.
    package var bitrateAdaptationCeiling: Int?

    /// Maximum encoded width in pixels for host-computed stream scaling.
    package var encoderMaxWidth: Int?

    /// Maximum encoded height in pixels for host-computed stream scaling.
    package var encoderMaxHeight: Int?

    /// Requested media packet size for this stream.
    package var mediaMaxPacketSize: Int?

    /// Client-observed control path kind at stream start.
    package var clientTransportPathKind: MirageNetworkPathKind?

    /// Client-observed media profile at stream start.
    package var clientMediaPathProfile: MirageMediaPathProfile?

    /// Diagnostic client control-path signature at stream start.
    package var clientPathSignature: String?

    /// Client-requested MetalFX upscaling mode.
    package var upscalingMode: MirageUpscalingMode?

    /// Client-requested video codec.
    package var codec: MirageVideoCodec?

    /// When true, the host should use its current display resolution instead of the client-provided dimensions.
    package var useHostResolution: Bool?

    /// Creates a desktop-stream startup request.
    package init(
        startupRequestID: UUID = UUID(),
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
        hostBufferingPolicy: MirageHostBufferingPolicy? = nil,
        allowRuntimeQualityAdjustment: Bool? = nil,
        allowEncoderCatchUpQualityAdjustment: Bool? = nil,
        lowLatencyHighResolutionCompressionBoost: Bool? = nil,
        disableResolutionCap: Bool? = nil,
        streamScale: CGFloat? = nil,
        audioConfiguration: MirageAudioConfiguration? = nil,
        dataPort: UInt16? = nil,
        useHostResolution: Bool? = nil,
        mediaMaxPacketSize: Int? = nil,
        clientTransportPathKind: MirageNetworkPathKind? = nil,
        clientMediaPathProfile: MirageMediaPathProfile? = nil,
        clientPathSignature: String? = nil
    ) {
        self.startupRequestID = startupRequestID
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
        self.hostBufferingPolicy = hostBufferingPolicy
        self.allowRuntimeQualityAdjustment = allowRuntimeQualityAdjustment
        self.allowEncoderCatchUpQualityAdjustment = allowEncoderCatchUpQualityAdjustment
        self.lowLatencyHighResolutionCompressionBoost = lowLatencyHighResolutionCompressionBoost
        self.disableResolutionCap = disableResolutionCap
        self.streamScale = streamScale
        self.audioConfiguration = audioConfiguration
        self.dataPort = dataPort
        self.useHostResolution = useHostResolution
        self.mediaMaxPacketSize = mediaMaxPacketSize
        self.clientTransportPathKind = clientTransportPathKind
        self.clientMediaPathProfile = clientMediaPathProfile
        self.clientPathSignature = clientPathSignature
    }

    /// Creates a copy of an existing desktop-start request with a new startup identity.
    package init(
        copying request: StartDesktopStreamMessage,
        startupRequestID: UUID = UUID(),
        targetFrameRate: Int? = nil
    ) {
        self.init(
            startupRequestID: startupRequestID,
            scaleFactor: request.scaleFactor,
            displayWidth: request.displayWidth,
            displayHeight: request.displayHeight,
            targetFrameRate: targetFrameRate ?? request.targetFrameRate,
            keyFrameInterval: request.keyFrameInterval,
            captureQueueDepth: request.captureQueueDepth,
            colorDepth: request.colorDepth,
            mode: request.mode,
            cursorPresentation: request.cursorPresentation,
            enteredBitrate: request.enteredBitrate,
            bitrate: request.bitrate,
            latencyMode: request.latencyMode,
            hostBufferingPolicy: request.hostBufferingPolicy,
            allowRuntimeQualityAdjustment: request.allowRuntimeQualityAdjustment,
            allowEncoderCatchUpQualityAdjustment: request.allowEncoderCatchUpQualityAdjustment,
            lowLatencyHighResolutionCompressionBoost: request.lowLatencyHighResolutionCompressionBoost,
            disableResolutionCap: request.disableResolutionCap,
            streamScale: request.streamScale,
            audioConfiguration: request.audioConfiguration,
            dataPort: request.dataPort,
            useHostResolution: request.useHostResolution,
            mediaMaxPacketSize: request.mediaMaxPacketSize,
            clientTransportPathKind: request.clientTransportPathKind,
            clientMediaPathProfile: request.clientMediaPathProfile,
            clientPathSignature: request.clientPathSignature
        )
        bitrateAdaptationCeiling = request.bitrateAdaptationCeiling
        encoderMaxWidth = request.encoderMaxWidth
        encoderMaxHeight = request.encoderMaxHeight
        upscalingMode = request.upscalingMode
        codec = request.codec
    }

    package var resolvedHostBufferingPolicy: MirageHostBufferingPolicy {
        hostBufferingPolicy ?? .freshestFrame
    }
}

/// Runtime desktop cursor presentation update (Client → Host).
package struct DesktopCursorPresentationChangeMessage: Codable {
    /// Desktop stream to update.
    package let streamID: StreamID

    /// New cursor presentation mode.
    package let cursorPresentation: MirageDesktopCursorPresentation

    /// Creates a runtime cursor presentation change message.
    package init(
        streamID: StreamID,
        cursorPresentation: MirageDesktopCursorPresentation
    ) {
        self.streamID = streamID
        self.cursorPresentation = cursorPresentation
    }
}

/// Client-to-host request to stop a desktop stream.
package struct StopDesktopStreamMessage: Codable {
    /// Desktop stream ID to stop.
    package let streamID: StreamID

    /// Session identifier for the active desktop stream.
    package let desktopSessionID: UUID

    /// Creates a desktop-stream stop request.
    package init(streamID: StreamID, desktopSessionID: UUID) {
        self.streamID = streamID
        self.desktopSessionID = desktopSessionID
    }
}

/// Client-to-host request to cancel in-progress stream setup before a stream ID exists.
package struct CancelStreamSetupMessage: Codable {
    /// Startup request to cancel, if known.
    package let startupRequestID: UUID?

    /// Setup family to cancel.
    package let kind: StreamSetupKind?

    /// App session to cancel when cancelling app-stream setup.
    package let appSessionID: UUID?

    /// Creates a stream-setup cancellation request.
    package init(
        startupRequestID: UUID? = nil,
        kind: StreamSetupKind? = nil,
        appSessionID: UUID? = nil
    ) {
        self.startupRequestID = startupRequestID
        self.kind = kind
        self.appSessionID = appSessionID
    }
}

/// Desktop presentation transition phase.
package enum MirageDesktopTransitionPhase: String, Codable {
    /// Initial desktop stream startup.
    case startup

    /// Live desktop resize.
    case resize
}

/// Outcome reported for a desktop presentation transition.
package enum MirageDesktopTransitionOutcome: String, Codable {
    /// No geometry change was needed.
    case noChange

    /// The desktop stream resized successfully.
    case resized

    /// The host rolled back to the prior desktop geometry.
    case rolledBack
}

/// Host capture source used for a desktop stream.
package enum MirageDesktopCaptureSource: String, Codable {
    /// Capture comes from a Mirage-created virtual display.
    case virtualDisplay

    /// Capture falls back to the physical main display.
    case mainDisplayFallback
}

/// Host-to-client confirmation that desktop streaming has started or resized.
package struct DesktopStreamStartedMessage: Codable {
    /// Stream ID for the desktop stream.
    package let streamID: StreamID

    /// Session identifier for the active desktop stream.
    package let desktopSessionID: UUID

    /// Encoded capture width in pixels.
    package let width: Int

    /// Encoded capture height in pixels.
    package let height: Int

    /// Frame rate of the stream.
    package let frameRate: Int

    /// Video codec being used.
    package let codec: MirageVideoCodec

    /// Startup-attempt identifier used to gate first-frame readiness.
    package let startupAttemptID: UUID?

    /// Number of physical displays being mirrored.
    package let displayCount: Int

    /// Dimension token for rejecting old-dimension P-frames after resize.
    package var dimensionToken: UInt16?

    /// Media packet size accepted by the host for this stream.
    package var acceptedMediaMaxPacketSize: Int?

    /// Optional transition identifier for resize commits.
    package var transitionID: UUID?

    /// Whether this packet describes initial startup or a live resize transition.
    package var transitionPhase: MirageDesktopTransitionPhase?

    /// Optional resize outcome metadata.
    package var transitionOutcome: MirageDesktopTransitionOutcome?

    /// Host-authoritative generation for desktop presentation geometry.
    package var desktopPresentationGeneration: UInt64?

    /// Effective host capture source for this desktop stream.
    package var captureSource: MirageDesktopCaptureSource

    /// Whether the client may request virtual-display resize transactions.
    package var allowsClientResize: Bool

    /// Host-accepted display scale for interpreting presentation geometry.
    package var acceptedDisplayScaleFactor: CGFloat?

    /// Client presentation/window sizing width, separate from capture pixels.
    package var presentationWidth: Int?

    /// Client presentation/window sizing height, separate from capture pixels.
    package var presentationHeight: Int?

    /// Client presentation size, falling back to capture size when not sent separately.
    package var presentationSize: CGSize {
        CGSize(
            width: presentationWidth ?? width,
            height: presentationHeight ?? height
        )
    }

    /// Creates a desktop-stream startup or resize confirmation.
    package init(
        streamID: StreamID,
        desktopSessionID: UUID,
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
        transitionOutcome: MirageDesktopTransitionOutcome? = nil,
        desktopPresentationGeneration: UInt64? = nil,
        captureSource: MirageDesktopCaptureSource = .virtualDisplay,
        allowsClientResize: Bool = true,
        acceptedDisplayScaleFactor: CGFloat? = nil,
        presentationWidth: Int? = nil,
        presentationHeight: Int? = nil
    ) {
        self.streamID = streamID
        self.desktopSessionID = desktopSessionID
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
        self.desktopPresentationGeneration = desktopPresentationGeneration
        self.captureSource = captureSource
        self.allowsClientResize = allowsClientResize
        self.acceptedDisplayScaleFactor = acceptedDisplayScaleFactor
        self.presentationWidth = presentationWidth
        self.presentationHeight = presentationHeight
    }
}

/// Host-to-client notification that a desktop stream stopped.
package struct DesktopStreamStoppedMessage: Codable {
    /// Stream ID that was stopped.
    package let streamID: StreamID

    /// Session identifier for the desktop stream that stopped.
    package let desktopSessionID: UUID

    /// Why the stream was stopped.
    package let reason: DesktopStreamStopReason

    /// Creates a desktop-stream stopped notification.
    package init(
        streamID: StreamID,
        desktopSessionID: UUID,
        reason: DesktopStreamStopReason
    ) {
        self.streamID = streamID
        self.desktopSessionID = desktopSessionID
        self.reason = reason
    }
}

/// Host-to-client notification that desktop stream startup failed.
package struct DesktopStreamFailedMessage: Codable {
    /// Human-readable reason the stream failed to start.
    package let reason: String

    /// Creates a desktop-stream startup failure notification.
    package init(reason: String) {
        self.reason = reason
    }
}

/// Reason why a desktop stream stopped.
public enum DesktopStreamStopReason: String, Codable, Sendable {
    /// Client requested the stop.
    case clientRequested

    /// User started an app stream.
    case appStreamStarted

    /// Host shut down or disconnected.
    case hostShutdown

    /// An error occurred.
    case error
}
