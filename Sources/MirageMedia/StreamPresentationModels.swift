//
//  StreamPresentationModels.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import Foundation
import MirageCore

/// Logical presentation category independent of the physical media stream.
public enum StreamPresentationKind: String, Sendable, Codable, Equatable, CaseIterable {
    /// Primary app-window presentation.
    case appWindow

    /// Desktop presentation.
    case desktop

    /// App-defined custom presentation.
    case custom
}

/// Product request for a logical stream presentation.
public struct StreamPresentationRequest: Sendable, Codable, Equatable {
    /// Stable presentation identity.
    public let id: StreamPresentationID

    /// Logical presentation category.
    public let kind: StreamPresentationKind

    /// Optional scene or owner identity that should claim the presentation.
    public let ownerID: UUID?

    /// Optional requested logical size in points.
    public let requestedSize: CGSize?

    /// Creates a stream presentation request.
    public init(
        id: StreamPresentationID = StreamPresentationID(),
        kind: StreamPresentationKind,
        ownerID: UUID? = nil,
        requestedSize: CGSize? = nil
    ) {
        self.id = id
        self.kind = kind
        self.ownerID = ownerID
        self.requestedSize = requestedSize
    }
}

/// Presentation policy selected for a stream recipe.
public struct MiragePresentationPolicy: Sendable, Codable, Equatable {
    /// Logical presentation category.
    public let kind: StreamPresentationKind

    /// Presentation request associated with this policy.
    public let request: StreamPresentationRequest?

    /// Whether the presentation should own primary focus when it appears.
    public let prefersPrimaryFocus: Bool

    /// Creates a presentation policy.
    public init(
        kind: StreamPresentationKind,
        request: StreamPresentationRequest? = nil,
        prefersPrimaryFocus: Bool = true
    ) {
        self.kind = kind
        self.request = request
        self.prefersPrimaryFocus = prefersPrimaryFocus
    }
}
