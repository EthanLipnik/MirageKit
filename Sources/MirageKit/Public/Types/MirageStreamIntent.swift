//
//  MirageStreamIntent.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation

/// Product-level request to start or adopt a stream presentation.
public enum MirageStreamIntent: Sendable, Codable, Equatable {
    /// Start an app-window streaming session.
    case app(MirageAppStreamIntent)

    /// Start a desktop streaming session.
    case desktop(MirageDesktopStreamIntent)

    /// Start an app-defined custom stream.
    case custom(MirageCustomStreamIntent)

    /// Broad stream family requested by this intent.
    public var streamKind: MirageMedia.MirageStreamKind {
        switch self {
        case .app:
            .app
        case .desktop:
            .desktop
        case .custom:
            .custom
        }
    }
}

/// Product intent for app-window streaming.
public struct MirageAppStreamIntent: Sendable, Codable, Equatable {
    /// Host app bundle identifier to stream.
    public let bundleIdentifier: String

    /// Optional client logical display resolution in points.
    public let displayResolution: CGSize?

    /// Presentation request associated with the first visible app window.
    public let presentationRequest: MirageMedia.StreamPresentationRequest?

    /// Creates an app-stream intent.
    public init(
        bundleIdentifier: String,
        displayResolution: CGSize? = nil,
        presentationRequest: MirageMedia.StreamPresentationRequest? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayResolution = displayResolution
        self.presentationRequest = presentationRequest
    }
}

/// Product intent for desktop streaming.
public struct MirageDesktopStreamIntent: Sendable, Codable, Equatable {
    /// Desktop stream mode requested by the product.
    public let mode: MirageMedia.MirageDesktopStreamMode

    /// Desktop cursor presentation requested by the product.
    public let cursorPresentation: MirageWire.MirageDesktopCursorPresentation

    /// Optional client drawable size in logical points.
    public let drawableSize: CGSize?

    /// Optional client drawable backing scale.
    public let drawableScaleFactor: CGFloat?

    /// Presentation request associated with the desktop surface.
    public let presentationRequest: MirageMedia.StreamPresentationRequest?

    /// Creates a desktop-stream intent.
    public init(
        mode: MirageMedia.MirageDesktopStreamMode = .unified,
        cursorPresentation: MirageWire.MirageDesktopCursorPresentation = .simulatedCursor,
        drawableSize: CGSize? = nil,
        drawableScaleFactor: CGFloat? = nil,
        presentationRequest: MirageMedia.StreamPresentationRequest? = nil
    ) {
        self.mode = mode
        self.cursorPresentation = cursorPresentation
        self.drawableSize = drawableSize
        self.drawableScaleFactor = drawableScaleFactor
        self.presentationRequest = presentationRequest
    }
}

/// Product intent for app-defined custom streaming.
public struct MirageCustomStreamIntent: Sendable, Codable, Equatable {
    /// App-defined stream request.
    public let request: MirageCustomStreamRequest

    /// Presentation request associated with the custom stream.
    public let presentationRequest: MirageMedia.StreamPresentationRequest?

    /// Creates a custom-stream intent.
    public init(
        request: MirageCustomStreamRequest,
        presentationRequest: MirageMedia.StreamPresentationRequest? = nil
    ) {
        self.request = request
        self.presentationRequest = presentationRequest
    }
}
