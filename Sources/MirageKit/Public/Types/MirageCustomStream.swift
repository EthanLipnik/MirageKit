//
//  MirageCustomStream.swift
//  MirageKit
//
//  Created by Codex on 4/30/26.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Broad stream family used by MirageKit surfaces and session metadata.
public enum MirageStreamKind: Hashable, Sendable, Codable {
    case app
    case desktop
    case custom
}

/// Host-published metadata for a custom stream source.
///
/// `kind` is the stable application-owned identifier used during negotiation,
/// for example `dev.example.product-display.v1`. MirageKit treats it as an
/// opaque string and does not attach product-specific meaning to it.
public struct MirageCustomStreamDescriptor: Hashable, Sendable, Codable {
    public let kind: String
    public let displayName: String
    public let metadata: [String: String]
    public let defaultWidth: Int
    public let defaultHeight: Int
    public let defaultFrameRate: Int
    public let supportsInput: Bool

    public init(
        kind: String,
        displayName: String,
        metadata: [String: String] = [:],
        defaultWidth: Int,
        defaultHeight: Int,
        defaultFrameRate: Int = 60,
        supportsInput: Bool = true
    ) {
        self.kind = kind
        self.displayName = displayName
        self.metadata = metadata
        self.defaultWidth = max(1, defaultWidth)
        self.defaultHeight = max(1, defaultHeight)
        self.defaultFrameRate = max(1, min(120, defaultFrameRate))
        self.supportsInput = supportsInput
    }
}

/// Client-to-host custom stream request passed to app-provided sources.
public struct MirageCustomStreamRequest: Hashable, Sendable, Codable {
    public let requestID: UUID
    public let kind: String
    public let metadata: [String: String]
    public let displayWidth: Int
    public let displayHeight: Int
    public let targetFrameRate: Int
    public let requiredPixelFormat: UInt32

    public init(
        requestID: UUID = UUID(),
        kind: String,
        metadata: [String: String] = [:],
        displayWidth: Int,
        displayHeight: Int,
        targetFrameRate: Int = 60,
        requiredPixelFormat: UInt32 = kCVPixelFormatType_32BGRA
    ) {
        self.requestID = requestID
        self.kind = kind
        self.metadata = metadata
        self.displayWidth = max(1, displayWidth)
        self.displayHeight = max(1, displayHeight)
        self.targetFrameRate = max(1, min(120, targetFrameRate))
        self.requiredPixelFormat = requiredPixelFormat
    }
}

/// A host-supplied frame for a custom stream.
///
/// Custom sources should emit pixel buffers in the request's
/// `requiredPixelFormat`. MirageKit owns encode, transport, decode, and
/// presentation after the frame is submitted.
public struct MirageCustomStreamFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let duration: CMTime
    public let contentRect: CGRect
    public let dirtyPercentage: Float
    public let isIdleFrame: Bool

    public init(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime,
        contentRect: CGRect? = nil,
        dirtyPercentage: Float = 100,
        isIdleFrame: Bool = false
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.duration = duration
        self.contentRect = contentRect ?? CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        self.dirtyPercentage = max(0, min(100, dirtyPercentage))
        self.isIdleFrame = isIdleFrame
    }
}

/// Sink passed by MirageKit to app-provided custom stream sources.
public final class MirageCustomStreamFrameSink: @unchecked Sendable {
    private let submitFrame: @Sendable (MirageCustomStreamFrame) -> Void

    package init(submitFrame: @escaping @Sendable (MirageCustomStreamFrame) -> Void) {
        self.submitFrame = submitFrame
    }

    public func submit(_ frame: MirageCustomStreamFrame) {
        submitFrame(frame)
    }
}

/// Active source session returned by a custom source after startup.
public protocol MirageCustomStreamSession: Sendable {
    var inputHandler: (any MirageCustomStreamInputHandler)? { get }

    func stop() async
}

/// Host-app implementation that produces frames for an opaque custom stream kind.
public protocol MirageCustomStreamSource: Sendable {
    var descriptor: MirageCustomStreamDescriptor { get }

    func startStream(
        request: MirageCustomStreamRequest,
        frameSink: MirageCustomStreamFrameSink
    ) async throws -> any MirageCustomStreamSession
}

/// Optional host-app input handler for a custom stream.
public protocol MirageCustomStreamInputHandler: Sendable {
    func handleInput(_ event: MirageInputEvent, streamID: StreamID) async
}
