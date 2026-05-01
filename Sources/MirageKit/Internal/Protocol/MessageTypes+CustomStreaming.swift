//
//  MessageTypes+CustomStreaming.swift
//  MirageKit
//
//  Created by Codex on 4/30/26.
//

import CoreGraphics
import CoreVideo
import Foundation

// MARK: - Custom Streaming Messages

package struct StartCustomStreamMessage: Codable, Sendable {
    package let startupRequestID: UUID
    package let kind: String
    package let metadata: [String: String]
    package let displayWidth: Int
    package let displayHeight: Int
    package let targetFrameRate: Int
    package let scaleFactor: CGFloat?
    package var keyFrameInterval: Int?
    package var colorDepth: MirageStreamColorDepth?
    package var bitrate: Int?
    package var latencyMode: MirageStreamLatencyMode?
    package var performanceMode: MirageStreamPerformanceMode?
    package var allowRuntimeQualityAdjustment: Bool?
    package var lowLatencyHighResolutionCompressionBoost: Bool?
    package var disableResolutionCap: Bool?
    package var streamScale: CGFloat?
    package var bitrateAdaptationCeiling: Int?
    package var encoderMaxWidth: Int?
    package var encoderMaxHeight: Int?
    package var mediaMaxPacketSize: Int?
    package var upscalingMode: MirageUpscalingMode?
    package var codec: MirageVideoCodec?

    package init(
        startupRequestID: UUID = UUID(),
        kind: String,
        metadata: [String: String] = [:],
        displayWidth: Int,
        displayHeight: Int,
        targetFrameRate: Int,
        scaleFactor: CGFloat? = nil,
        streamScale: CGFloat? = nil,
        mediaMaxPacketSize: Int? = nil
    ) {
        self.startupRequestID = startupRequestID
        self.kind = kind
        self.metadata = metadata
        self.displayWidth = max(1, displayWidth)
        self.displayHeight = max(1, displayHeight)
        self.targetFrameRate = max(1, min(120, targetFrameRate))
        self.scaleFactor = scaleFactor
        self.streamScale = streamScale
        self.mediaMaxPacketSize = mediaMaxPacketSize
    }

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
}

package struct StopCustomStreamMessage: Codable, Sendable {
    package let streamID: StreamID

    package init(streamID: StreamID) {
        self.streamID = streamID
    }
}

public struct MirageCustomStreamStartedMessage: Codable, Sendable, Equatable {
    public let startupRequestID: UUID
    public let streamID: StreamID
    public let descriptor: MirageCustomStreamDescriptor
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public let codec: MirageVideoCodec
    public let startupAttemptID: UUID?
    public let dimensionToken: UInt16?
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

public struct MirageCustomStreamStoppedMessage: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case clientRequested
        case sourceStopped
        case hostShutdown
        case error
    }

    public let streamID: StreamID
    public let reason: Reason

    package init(streamID: StreamID, reason: Reason) {
        self.streamID = streamID
        self.reason = reason
    }
}

package struct CustomStreamFailedMessage: Codable, Sendable {
    package let startupRequestID: UUID
    package let kind: String
    package let reason: String
    package let errorCode: ErrorMessage.ErrorCode

    package init(
        startupRequestID: UUID,
        kind: String,
        reason: String,
        errorCode: ErrorMessage.ErrorCode
    ) {
        self.startupRequestID = startupRequestID
        self.kind = kind
        self.reason = reason
        self.errorCode = errorCode
    }
}
