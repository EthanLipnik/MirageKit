//
//  MirageStreamSessionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit
import Observation

/// Observable state for one logical stream session in the client UI.
@Observable
@MainActor
public final class MirageStreamSessionState: Identifiable {
    /// Stable UI identity for this stream session.
    public let id: StreamSessionID

    /// Logical stream ID used for control, focus, and input.
    public let streamID: StreamID

    /// Physical media stream ID used for decoded frame presentation.
    public let mediaStreamID: StreamID

    /// Latest host window metadata associated with the stream.
    public var window: MirageWindow

    /// Display name of the host that owns the stream.
    public let hostName: String

    /// Host app-session identifier for app streams, when available.
    public let appSessionID: UUID?

    /// Whether this session represents an app, desktop, or custom stream.
    public let streamKind: MirageStreamKind

    /// Stable logical target used to map host updates back to the session.
    public let logicalTarget: MirageStreamLogicalTarget

    /// Current atlas placement for multi-window app streams.
    public var atlasRegion: MirageAppAtlasRegion?

    /// Latest stream statistics received from the host.
    public var statistics: MirageStreamStatistics?

    /// Client-side recovery state surfaced to stream UI.
    public var clientRecoveryStatus: MirageStreamClientRecoveryStatus

    /// Client-side recovery cause reported back to the host.
    public var clientRecoveryCause: MirageStreamClientRecoveryCause

    /// Whether the decoder has produced at least one frame for this session.
    public var hasDecodedFrame: Bool

    /// Whether the renderer has presented at least one frame for this session.
    public var hasPresentedFrame: Bool

    /// Minimum window width in points, as reported by the host.
    public var minWidth: CGFloat = 400

    /// Minimum window height in points, as reported by the host.
    public var minHeight: CGFloat = 300

    /// Creates active stream session state for the client session store.
    public init(
        id: StreamSessionID,
        streamID: StreamID,
        mediaStreamID: StreamID,
        window: MirageWindow,
        hostName: String,
        appSessionID: UUID? = nil,
        streamKind: MirageStreamKind = .app,
        logicalTarget: MirageStreamLogicalTarget? = nil,
        atlasRegion: MirageAppAtlasRegion? = nil,
        statistics: MirageStreamStatistics? = nil,
        clientRecoveryStatus: MirageStreamClientRecoveryStatus = .idle,
        clientRecoveryCause: MirageStreamClientRecoveryCause = .none,
        hasDecodedFrame: Bool = false,
        hasPresentedFrame: Bool = false,
        minWidth: CGFloat = 400,
        minHeight: CGFloat = 300
    ) {
        self.id = id
        self.streamID = streamID
        self.mediaStreamID = mediaStreamID
        self.window = window
        self.hostName = hostName
        self.appSessionID = appSessionID
        self.streamKind = streamKind
        self.logicalTarget = logicalTarget ?? MirageStreamLogicalTarget(
            streamID: streamID,
            window: window,
            streamKind: streamKind,
            appSessionID: appSessionID
        )
        self.atlasRegion = atlasRegion
        self.statistics = statistics
        self.clientRecoveryStatus = clientRecoveryStatus
        self.clientRecoveryCause = clientRecoveryStatus == .idle ? .none : clientRecoveryCause
        self.hasDecodedFrame = hasDecodedFrame
        self.hasPresentedFrame = hasPresentedFrame
        self.minWidth = minWidth
        self.minHeight = minHeight
    }
}
