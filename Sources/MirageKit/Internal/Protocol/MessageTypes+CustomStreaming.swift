//
//  MessageTypes+CustomStreaming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/30/26.
//

import CoreGraphics
import CoreVideo
import Foundation

// MARK: - Custom Streaming Messages

/// Client-to-host request to start an app-defined custom stream.
package struct StartCustomStreamMessage: Codable {
    /// Request-scoped identifier used to cancel or reject stale startup work.
    package let startupRequestID: UUID

    /// App-defined stream kind.
    package let kind: String

    /// App-defined metadata describing the requested stream.
    package let metadata: [String: String]

    /// Client display width in points.
    package let displayWidth: Int

    /// Client display height in points.
    package let displayHeight: Int

    /// Client-selected target frame rate in Hz.
    package let targetFrameRate: Int

    /// Client-requested keyframe interval in frames.
    package var keyFrameInterval: Int?

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

    /// Client-requested post-capture stream scale.
    package var streamScale: CGFloat?

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

    /// Creates a custom-stream startup request.
    package init(
        startupRequestID: UUID = UUID(),
        kind: String,
        metadata: [String: String] = [:],
        displayWidth: Int,
        displayHeight: Int,
        targetFrameRate: Int,
        streamScale: CGFloat? = nil,
        mediaMaxPacketSize: Int? = nil,
        clientTransportPathKind: MirageNetworkPathKind? = nil,
        clientMediaPathProfile: MirageMediaPathProfile? = nil,
        clientPathSignature: String? = nil
    ) {
        self.startupRequestID = startupRequestID
        self.kind = kind
        self.metadata = metadata
        self.displayWidth = max(1, displayWidth)
        self.displayHeight = max(1, displayHeight)
        self.targetFrameRate = max(1, min(120, targetFrameRate))
        self.streamScale = streamScale
        self.mediaMaxPacketSize = mediaMaxPacketSize
        self.clientTransportPathKind = clientTransportPathKind
        self.clientMediaPathProfile = clientMediaPathProfile
        self.clientPathSignature = clientPathSignature
    }

    /// Public request handed to custom stream providers.
    package var publicRequest: MirageCustomStreamRequest {
        MirageCustomStreamRequest(
            requestID: startupRequestID,
            kind: kind,
            metadata: metadata,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            targetFrameRate: targetFrameRate,
            requiredPixelFormat: kCVPixelFormatType_32BGRA
        )
    }

    package var resolvedHostBufferingPolicy: MirageHostBufferingPolicy {
        hostBufferingPolicy ?? .freshestFrame
    }
}

/// Client-to-host request to stop a custom stream.
package struct StopCustomStreamMessage: Codable {
    /// Stream to stop.
    package let streamID: StreamID

    /// Creates a custom-stream stop request.
    package init(streamID: StreamID) {
        self.streamID = streamID
    }
}

/// Host-to-client notification that a custom stream has started.
public struct MirageCustomStreamStartedMessage: Codable, Sendable, Equatable {
    /// Client-provided startup request identifier.
    public let startupRequestID: UUID

    /// Stream identifier assigned by the host.
    public let streamID: StreamID

    /// Descriptor for the app-defined source backing the stream.
    public let descriptor: MirageCustomStreamDescriptor

    /// Encoded stream width in pixels.
    public let width: Int

    /// Encoded stream height in pixels.
    public let height: Int

    /// Initial frame rate selected for the stream.
    public let frameRate: Int

    /// Video codec selected for the stream.
    public let codec: MirageVideoCodec

    /// Host startup attempt identifier used for diagnostics.
    public let startupAttemptID: UUID?

    /// Host dimension token used to correlate frame geometry.
    public let dimensionToken: UInt16?

    /// Negotiated media packet size for the stream.
    public let acceptedMediaMaxPacketSize: Int?

    package init(
        startupRequestID: UUID,
        streamID: StreamID,
        descriptor: MirageCustomStreamDescriptor,
        width: Int,
        height: Int,
        frameRate: Int,
        codec: MirageVideoCodec,
        startupAttemptID: UUID?,
        dimensionToken: UInt16?,
        acceptedMediaMaxPacketSize: Int?
    ) {
        self.startupRequestID = startupRequestID
        self.streamID = streamID
        self.descriptor = descriptor
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.startupAttemptID = startupAttemptID
        self.dimensionToken = dimensionToken
        self.acceptedMediaMaxPacketSize = acceptedMediaMaxPacketSize
    }
}

/// Host-to-client notification that a custom stream has stopped.
public struct MirageCustomStreamStoppedMessage: Codable, Sendable, Equatable {
    /// Reason the custom stream stopped.
    public enum Reason: String, Codable, Sendable {
        /// Client requested the stop.
        case clientRequested

        /// The app-defined source stopped producing frames.
        case sourceStopped

        /// Host shut down or disconnected.
        case hostShutdown

        /// The stream stopped because of an error.
        case error
    }

    /// Stream identifier that stopped.
    public let streamID: StreamID

    /// Reason the stream stopped.
    public let reason: Reason

    package init(streamID: StreamID, reason: Reason) {
        self.streamID = streamID
        self.reason = reason
    }
}

/// Host-to-client notification that a custom stream failed to start.
package struct CustomStreamFailedMessage: Codable {
    /// Startup request that failed.
    package let startupRequestID: UUID

    /// Human-readable failure reason.
    package let reason: String

    /// Creates a custom-stream startup failure payload.
    package init(
        startupRequestID: UUID,
        reason: String
    ) {
        self.startupRequestID = startupRequestID
        self.reason = reason
    }
}
