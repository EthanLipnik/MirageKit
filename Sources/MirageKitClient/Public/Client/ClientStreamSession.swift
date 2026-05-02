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
    public enum Kind: String, Hashable, Sendable, Codable {
        case appWindow
        case desktop
        case custom
    }

    public let kind: Kind
    public let streamID: StreamID
    public let windowID: WindowID?
    public let appSessionID: UUID?

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

    public init(
        streamID: StreamID,
        window: MirageWindow,
        streamKind: MirageStreamKind,
        appSessionID: UUID? = nil
    ) {
        self.init(
            kind: Self.kind(for: streamKind),
            streamID: streamID,
            windowID: streamKind == .desktop ? nil : window.id,
            appSessionID: appSessionID
        )
    }

    private static func kind(for streamKind: MirageStreamKind) -> Kind {
        switch streamKind {
        case .app:
            .appWindow
        case .desktop:
            .desktop
        case .custom:
            .custom
        }
    }
}

public struct ClientStreamSession: Identifiable, Sendable {
    /// Logical stream ID used for control, focus, and input.
    public let id: StreamID
    /// Physical media stream ID used for decoded frame presentation.
    public let mediaStreamID: StreamID
    public let window: MirageWindow
    public let kind: MirageStreamKind
    public let logicalTarget: MirageStreamLogicalTarget
    public let atlasRegion: MirageAppAtlasRegion?

    public init(
        id: StreamID,
        window: MirageWindow,
        kind: MirageStreamKind = .app,
        mediaStreamID: StreamID? = nil,
        logicalTarget: MirageStreamLogicalTarget? = nil,
        atlasRegion: MirageAppAtlasRegion? = nil
    ) {
        self.id = id
        self.mediaStreamID = mediaStreamID ?? id
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
