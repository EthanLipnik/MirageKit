//
//  MirageDesktopStreamingMessages.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//
//  Desktop streaming control message definitions.
//

import CoreGraphics
import Foundation
import MirageCore
import MirageMedia

/// Stream setup family used to scope cancellation and startup handling.
package enum StreamSetupKind: String, Codable {
    /// App-window stream setup.
    case app

    /// Desktop stream setup.
    case desktop

    /// Custom stream setup.
    case custom
}

/// Runtime desktop cursor presentation update (Client -> Host).
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

/// Client presentation role for a desktop stream.
package enum MirageDesktopPresentationRole: String, Codable {
    /// A normal user-requested desktop stream.
    case desktop

    /// A temporary desktop stream shown while an app stream waits for the host session to unlock.
    case appStreamPlaceholder
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
    package let codec: MirageMedia.MirageVideoCodec

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

    /// Geometry contract identity accepted by the host for this startup or resize transition.
    package var desktopGeometryContractID: UUID?

    /// Diagnostic scene identity associated with the accepted client drawable.
    package var desktopGeometrySceneIdentity: String?

    /// Host-accepted display pixel width for the geometry contract.
    package var desktopGeometryDisplayPixelWidth: Int?

    /// Host-accepted display pixel height for the geometry contract.
    package var desktopGeometryDisplayPixelHeight: Int?

    /// Host-accepted encoded pixel width for the geometry contract.
    package var desktopGeometryEncodedPixelWidth: Int?

    /// Host-accepted encoded pixel height for the geometry contract.
    package var desktopGeometryEncodedPixelHeight: Int?

    /// Host-accepted refresh target for the geometry contract.
    package var desktopGeometryRefreshTargetHz: Int?

    /// Client presentation role for this desktop stream.
    package var presentationRole: MirageDesktopPresentationRole?

    /// App session associated with an app-stream placeholder.
    package var associatedAppSessionID: UUID?

    /// App startup request associated with an app-stream placeholder.
    package var associatedAppStartupRequestID: UUID?

    /// App bundle associated with an app-stream placeholder.
    package var associatedBundleIdentifier: String?

    /// Client presentation size, falling back to capture size when not sent separately.
    package var presentationSize: CGSize {
        CGSize(
            width: presentationWidth ?? width,
            height: presentationHeight ?? height
        )
    }

    /// Geometry contract the client should echo when acknowledging desktop startup readiness.
    package var streamReadyDesktopGeometryContract: StreamReadyDesktopGeometryContract? {
        guard let desktopGeometryContractID else { return nil }
        return StreamReadyDesktopGeometryContract(
            contractID: desktopGeometryContractID,
            sceneIdentity: desktopGeometrySceneIdentity,
            logicalWidth: Int(presentationSize.width.rounded()),
            logicalHeight: Int(presentationSize.height.rounded()),
            displayPixelWidth: desktopGeometryDisplayPixelWidth ?? width,
            displayPixelHeight: desktopGeometryDisplayPixelHeight ?? height,
            encodedPixelWidth: desktopGeometryEncodedPixelWidth ?? width,
            encodedPixelHeight: desktopGeometryEncodedPixelHeight ?? height,
            refreshTargetHz: desktopGeometryRefreshTargetHz
        )
    }

    /// Creates a desktop-stream startup or resize confirmation.
    package init(
        streamID: StreamID,
        desktopSessionID: UUID,
        width: Int,
        height: Int,
        frameRate: Int,
        codec: MirageMedia.MirageVideoCodec,
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
        presentationHeight: Int? = nil,
        desktopGeometryContractID: UUID? = nil,
        desktopGeometrySceneIdentity: String? = nil,
        desktopGeometryDisplayPixelWidth: Int? = nil,
        desktopGeometryDisplayPixelHeight: Int? = nil,
        desktopGeometryEncodedPixelWidth: Int? = nil,
        desktopGeometryEncodedPixelHeight: Int? = nil,
        desktopGeometryRefreshTargetHz: Int? = nil,
        presentationRole: MirageDesktopPresentationRole? = nil,
        associatedAppSessionID: UUID? = nil,
        associatedAppStartupRequestID: UUID? = nil,
        associatedBundleIdentifier: String? = nil
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
        self.desktopGeometryContractID = desktopGeometryContractID
        self.desktopGeometrySceneIdentity = desktopGeometrySceneIdentity
        self.desktopGeometryDisplayPixelWidth = desktopGeometryDisplayPixelWidth
        self.desktopGeometryDisplayPixelHeight = desktopGeometryDisplayPixelHeight
        self.desktopGeometryEncodedPixelWidth = desktopGeometryEncodedPixelWidth
        self.desktopGeometryEncodedPixelHeight = desktopGeometryEncodedPixelHeight
        self.desktopGeometryRefreshTargetHz = desktopGeometryRefreshTargetHz
        self.presentationRole = presentationRole
        self.associatedAppSessionID = associatedAppSessionID
        self.associatedAppStartupRequestID = associatedAppStartupRequestID
        self.associatedBundleIdentifier = associatedBundleIdentifier
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
