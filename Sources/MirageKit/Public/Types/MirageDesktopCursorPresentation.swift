//
//  MirageDesktopCursorPresentation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

import Foundation

/// Cursor source choices for desktop streams.
public enum MirageDesktopCursorSource: String, Codable, Sendable, CaseIterable, Hashable {
    /// Render the client-side Mirage cursor instead of capturing the host cursor in the stream.
    case client

    /// Capture and display the real host cursor inside the streamed desktop image.
    case host

    public var displayName: String {
        switch self {
        case .client:
            "Mirage Cursor"
        case .host:
            "Real Mac Cursor"
        }
    }
}

/// Cursor presentation configuration for desktop streams.
public struct MirageDesktopCursorPresentation: Codable, Equatable, Sendable, Hashable {
    /// Which cursor source should be visible to the user.
    public var source: MirageDesktopCursorSource

    /// Whether the client should lock and hide its local cursor when the host cursor is captured.
    public var lockClientCursorWhenUsingHostCursor: Bool

    public init(
        source: MirageDesktopCursorSource = .client,
        lockClientCursorWhenUsingHostCursor: Bool = true
    ) {
        self.source = source
        self.lockClientCursorWhenUsingHostCursor = lockClientCursorWhenUsingHostCursor
    }

    /// Default desktop cursor presentation.
    public static let clientCursor = MirageDesktopCursorPresentation()

    public var capturesHostCursor: Bool {
        source == .host
    }

    public var rendersSyntheticClientCursor: Bool {
        source == .client
    }

    public func locksClientCursor(for mode: MirageDesktopStreamMode) -> Bool {
        switch source {
        case .client:
            mode == .secondary
        case .host:
            lockClientCursorWhenUsingHostCursor
        }
    }
}
