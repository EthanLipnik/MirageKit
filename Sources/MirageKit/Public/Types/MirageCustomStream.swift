//
//  MirageCustomStream.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/30/26.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Broad stream family used by MirageKit surfaces and session metadata.
public enum MirageStreamKind: Hashable, Sendable, Codable {
    /// Stream captures a host application window.
    case app
    /// Stream captures a host desktop or virtual display.
    case desktop
    /// Stream is supplied by application-defined custom media.
    case custom
}

/// Host-published metadata for a custom stream source.
///
/// `kind` is the stable application-owned identifier used during negotiation,
/// for example `dev.example.product-display.v1`. MirageKit treats it as an
/// opaque string and does not attach product-specific meaning to it.
public struct MirageCustomStreamDescriptor: Hashable, Sendable, Codable {
    /// Stable app-defined stream kind identifier.
    public let kind: String

    /// User-facing name for the custom stream source.
    public let displayName: String

    /// App-defined metadata published with the source descriptor.
    public let metadata: [String: String]

    /// Default source width in pixels.
    public let defaultWidth: Int

    /// Default source height in pixels.
    public let defaultHeight: Int

    /// Default source frame rate.
    public let defaultFrameRate: Int

    /// Whether the source accepts client input events.
    public let supportsInput: Bool

    /// Creates a descriptor for an app-defined stream source.
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
    /// Client-generated request identifier.
    public let requestID: UUID

    /// App-defined stream kind identifier.
    public let kind: String

    /// App-defined metadata attached to the request.
    public let metadata: [String: String]

    /// Requested display width in pixels.
    public let displayWidth: Int

    /// Requested display height in pixels.
    public let displayHeight: Int

    /// Requested frame rate.
    public let targetFrameRate: Int

    /// Required Core Video pixel format for submitted frames.
    public let requiredPixelFormat: UInt32

    /// Creates a client request for an app-defined stream source.
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
    /// Frame pixel buffer.
    public let pixelBuffer: CVPixelBuffer

    /// Presentation timestamp for the frame.
    public let presentationTime: CMTime

    /// Intended frame duration.
    public let duration: CMTime

    /// Content rectangle within the frame.
    public let contentRect: CGRect

    /// Estimated dirty percentage for encoder prioritization.
    public let dirtyPercentage: Float

    /// Whether this is an idle refresh frame.
    public let isIdleFrame: Bool

    /// Creates a custom stream frame from an app-provided pixel buffer.
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

    /// Submits one frame to the active custom stream.
    public func submit(_ frame: MirageCustomStreamFrame) {
        submitFrame(frame)
    }
}

/// Active source session returned by a custom source after startup.
public protocol MirageCustomStreamSession: Sendable {
    /// Optional input handler that receives client input for the stream.
    var inputHandler: (any MirageCustomStreamInputHandler)? { get }

    /// Stops the source session and releases source-owned resources.
    func stop() async
}

/// Host-app implementation that produces frames for an opaque custom stream kind.
public protocol MirageCustomStreamSource: Sendable {
    /// Published descriptor for this source.
    var descriptor: MirageCustomStreamDescriptor { get }

    /// Starts producing frames for a client request.
    func startStream(
        request: MirageCustomStreamRequest,
        frameSink: MirageCustomStreamFrameSink
    ) async throws -> any MirageCustomStreamSession
}

/// Optional host-app input handler for a custom stream.
public protocol MirageCustomStreamInputHandler: Sendable {
    /// Handles a client input event targeting the custom stream.
    func handleInput(_ event: MirageInputEvent, streamID: StreamID) async
}
