//
//  StreamSnapshotModels.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore
import MirageMedia

/// Value snapshot of a physical stream session.
public struct StreamSessionSnapshot: Sendable, Codable, Equatable {
    /// Stable logical session identity.
    public let id: StreamSessionID

    /// Stream family represented by this session.
    public let kind: MirageMedia.MirageStreamKind

    /// Logical control/input stream identifier.
    public let streamID: StreamID

    /// Physical media stream identifier.
    public let mediaStreamID: StreamID

    /// Optional app stream session identity.
    public let appSessionID: UUID?

    /// Presentation identities currently rendering this session.
    public let presentationIDs: [StreamPresentationID]

    /// Creates a session snapshot.
    public init(
        id: StreamSessionID,
        kind: MirageMedia.MirageStreamKind,
        streamID: StreamID,
        mediaStreamID: StreamID,
        appSessionID: UUID? = nil,
        presentationIDs: [StreamPresentationID] = []
    ) {
        self.id = id
        self.kind = kind
        self.streamID = streamID
        self.mediaStreamID = mediaStreamID
        self.appSessionID = appSessionID
        self.presentationIDs = presentationIDs
    }
}

/// Value snapshot of one logical stream presentation.
public struct StreamPresentationSnapshot: Sendable, Codable, Equatable {
    /// Stable logical presentation identity.
    public let id: StreamPresentationID

    /// Presentation category.
    public let kind: MirageMedia.StreamPresentationKind

    /// Optional owning scene or product state identity.
    public let ownerID: UUID?

    /// Logical session currently backing this presentation.
    public let sessionID: StreamSessionID?

    /// Logical control/input stream identifier.
    public let streamID: StreamID?

    /// Physical media stream identifier.
    public let mediaStreamID: StreamID?

    /// Creates a presentation snapshot.
    public init(
        id: StreamPresentationID,
        kind: MirageMedia.StreamPresentationKind,
        ownerID: UUID? = nil,
        sessionID: StreamSessionID? = nil,
        streamID: StreamID? = nil,
        mediaStreamID: StreamID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.ownerID = ownerID
        self.sessionID = sessionID
        self.streamID = streamID
        self.mediaStreamID = mediaStreamID
    }
}
