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

    enum CodingKeys: String, CodingKey {
        case startupRequestID
        case kind
        case metadata
        case displayWidth
        case displayHeight
        case targetFrameRate
        case scaleFactor
        case keyFrameInterval
        case colorDepth
        case bitrate
        case latencyMode
        case allowRuntimeQualityAdjustment
        case lowLatencyHighResolutionCompressionBoost
        case disableResolutionCap
        case streamScale
        case bitrateAdaptationCeiling
        case encoderMaxWidth
        case encoderMaxHeight
        case mediaMaxPacketSize
        case upscalingMode
        case codec
    }

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

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startupRequestID = (try? container.decodeIfPresent(UUID.self, forKey: .startupRequestID)) ?? UUID()
        kind = try container.decode(String.self, forKey: .kind)
        metadata = container.decodeLossyIfPresent([String: String].self, forKey: .metadata) ?? [:]
        displayWidth = max(1, container.decodeLossyIfPresent(Int.self, forKey: .displayWidth) ?? 1)
        displayHeight = max(1, container.decodeLossyIfPresent(Int.self, forKey: .displayHeight) ?? 1)
        targetFrameRate = max(
            1,
            min(120, container.decodeLossyIfPresent(Int.self, forKey: .targetFrameRate) ?? 60)
        )
        scaleFactor = container.decodeLossyIfPresent(CGFloat.self, forKey: .scaleFactor)
        keyFrameInterval = container.decodeLossyIfPresent(Int.self, forKey: .keyFrameInterval)
        colorDepth = container.decodeLossyIfPresent(MirageStreamColorDepth.self, forKey: .colorDepth)
        bitrate = container.decodeLossyIfPresent(Int.self, forKey: .bitrate)
        latencyMode = container.decodeLossyIfPresent(MirageStreamLatencyMode.self, forKey: .latencyMode)
        allowRuntimeQualityAdjustment = container.decodeLossyIfPresent(
            Bool.self,
            forKey: .allowRuntimeQualityAdjustment
        )
        lowLatencyHighResolutionCompressionBoost = container.decodeLossyIfPresent(
            Bool.self,
            forKey: .lowLatencyHighResolutionCompressionBoost
        )
        disableResolutionCap = container.decodeLossyIfPresent(Bool.self, forKey: .disableResolutionCap)
        streamScale = container.decodeLossyIfPresent(CGFloat.self, forKey: .streamScale)
        bitrateAdaptationCeiling = container.decodeLossyIfPresent(Int.self, forKey: .bitrateAdaptationCeiling)
        encoderMaxWidth = container.decodeLossyIfPresent(Int.self, forKey: .encoderMaxWidth)
        encoderMaxHeight = container.decodeLossyIfPresent(Int.self, forKey: .encoderMaxHeight)
        mediaMaxPacketSize = container.decodeLossyIfPresent(Int.self, forKey: .mediaMaxPacketSize)
        upscalingMode = container.decodeLossyIfPresent(MirageUpscalingMode.self, forKey: .upscalingMode)
        codec = container.decodeLossyIfPresent(MirageVideoCodec.self, forKey: .codec)
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

private extension KeyedDecodingContainer {
    func decodeLossyIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
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
