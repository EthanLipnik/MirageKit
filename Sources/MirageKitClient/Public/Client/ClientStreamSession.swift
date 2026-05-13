//
//  ClientStreamSession.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream session metadata for client-side UI coordination.
//

import MirageKit

/// Logical client-side target represented by a stream session.
///
/// `streamID` is the control/input identity. The target may render from a
/// different media stream when multiple logical windows share one physical feed.
public struct MirageStreamLogicalTarget: Hashable, Sendable, Codable {
    /// Logical stream target category used for focus and input routing.
    public enum Kind: String, Hashable, Sendable, Codable {
        /// A window inside an app-streaming session.
        case appWindow

        /// A desktop stream target.
        case desktop

        /// A caller-defined custom stream target.
        case custom
    }

    /// Target category.
    public let kind: Kind

    /// Logical control/input stream identifier.
    public let streamID: StreamID

    /// Host window identifier for window-backed targets.
    public let windowID: WindowID?

    /// App-stream session identifier for grouped app-window targets.
    public let appSessionID: UUID?

    /// Creates a logical stream target.
    public init(
        kind: Kind,
        streamID: StreamID,
        windowID: WindowID? = nil,
        appSessionID: UUID? = nil
    ) {
        self.kind = kind
        self.streamID = streamID
        self.windowID = windowID
        self.appSessionID = appSessionID
    }

    /// Creates a logical target from a stream kind and window.
    ///
    /// Desktop streams intentionally omit `windowID` because their control target is
    /// the desktop stream itself; app and custom streams keep the window identity.
    public init(
        streamID: StreamID,
        window: MirageWindow,
        streamKind: MirageStreamKind,
        appSessionID: UUID? = nil
    ) {
        let kind: Kind = switch streamKind {
        case .app:
            .appWindow
        case .desktop:
            .desktop
        case .custom:
            .custom
        }

        self.init(
            kind: kind,
            streamID: streamID,
            windowID: streamKind == .desktop ? nil : window.id,
            appSessionID: appSessionID
        )
    }
}

/// Client-side stream record used by UI and input routing.
///
/// `id` is the logical control target. `mediaStreamID` can differ when several
/// logical app windows are presented from a shared atlas media stream.
public struct ClientStreamSession: Identifiable, Sendable {
    /// Logical stream ID used for control, focus, and input.
    public let id: StreamID
    /// Physical media stream ID used for decoded frame presentation.
    public let mediaStreamID: StreamID
    /// Last known host window metadata for this stream.
    public let window: MirageWindow
    /// Host stream category.
    public let kind: MirageStreamKind
    /// Stable target used for focus, input, and scene coordination.
    public let logicalTarget: MirageStreamLogicalTarget
    /// Optional atlas slice when this logical stream is rendered from shared media.
    public let atlasRegion: MirageAppAtlasRegion?

    /// Creates a client stream session.
    ///
    /// When no explicit `logicalTarget` is supplied, the session builds one from
    /// the logical stream ID, window metadata, and stream kind.
    public init(
        id: StreamID,
        window: MirageWindow,
        kind: MirageStreamKind = .app,
        mediaStreamID: StreamID,
        logicalTarget: MirageStreamLogicalTarget? = nil,
        atlasRegion: MirageAppAtlasRegion? = nil
    ) {
        self.id = id
        self.mediaStreamID = mediaStreamID
        self.window = window
        self.kind = kind
        self.logicalTarget = logicalTarget ?? MirageStreamLogicalTarget(
            streamID: id,
            window: window,
            streamKind: kind
        )
        self.atlasRegion = atlasRegion
    }
}
