//
//  MirageDesktopCursorPresentation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

import Foundation

/// Cursor source choices for desktop streams.
public enum MirageDesktopCursorSource: String, Codable, Sendable, CaseIterable, Hashable {
    /// Show the local client cursor instead of capturing the host cursor in the stream.
    case client

    /// Render Mirage's software cursor instead of capturing the host cursor in the stream.
    case simulated

    /// Capture and display the real host cursor inside the streamed desktop image.
    case host

    public var displayName: String {
        switch self {
        case .client:
            "Client"
        case .simulated:
            "Simulated"
        case .host:
            "Host"
        }
    }

    public var footerDescription: String {
        switch self {
        case .client:
            "Client uses your local cursor."
        case .simulated:
            "Simulated draws Mirage's software cursor."
        case .host:
            "Host captures the real Mac cursor inside the stream."
        }
    }
}

/// Cursor presentation configuration for desktop streams.
public struct MirageDesktopCursorPresentation: Codable, Equatable, Sendable, Hashable {
    /// Which cursor source should be visible to the user.
    public var source: MirageDesktopCursorSource

    /// Whether the client should lock and hide its local cursor when Mirage renders the local cursor.
    public var lockClientCursorWhenUsingMirageCursor: Bool

    /// Whether the client should lock and hide its local cursor when the host cursor is captured.
    public var lockClientCursorWhenUsingHostCursor: Bool

    public init(
        source: MirageDesktopCursorSource = .simulated,
        lockClientCursorWhenUsingMirageCursor: Bool = false,
        lockClientCursorWhenUsingHostCursor: Bool = true
    ) {
        self.source = source
        self.lockClientCursorWhenUsingMirageCursor = lockClientCursorWhenUsingMirageCursor
        self.lockClientCursorWhenUsingHostCursor = lockClientCursorWhenUsingHostCursor
    }

    /// Default desktop cursor presentation.
    public static let simulatedCursor = MirageDesktopCursorPresentation()

    public var capturesHostCursor: Bool {
        source == .host
    }

    public var rendersSyntheticClientCursor: Bool {
        source == .simulated
    }

    public var requiresCursorPositionUpdates: Bool {
        source != .simulated
    }

    public var hidesLocalCursor: Bool {
        switch source {
        case .client:
            false
        case .simulated, .host:
            true
        }
    }

    public func lockClientCursorPreference(for source: MirageDesktopCursorSource? = nil) -> Bool {
        switch source ?? self.source {
        case .client, .simulated:
            lockClientCursorWhenUsingMirageCursor
        case .host:
            lockClientCursorWhenUsingHostCursor
        }
    }

    public mutating func setLockClientCursorPreference(
        _ isEnabled: Bool,
        for source: MirageDesktopCursorSource? = nil
    ) {
        switch source ?? self.source {
        case .client, .simulated:
            lockClientCursorWhenUsingMirageCursor = isEnabled
        case .host:
            lockClientCursorWhenUsingHostCursor = isEnabled
        }
    }

    public func canToggleLockClientCursor(for mode: MirageDesktopStreamMode) -> Bool {
        switch source {
        case .client, .simulated:
            mode != .secondary
        case .host:
            true
        }
    }

    public func locksClientCursor(for mode: MirageDesktopStreamMode) -> Bool {
        switch source {
        case .client, .simulated:
            mode == .secondary || lockClientCursorWhenUsingMirageCursor
        case .host:
            lockClientCursorWhenUsingHostCursor
        }
    }
}
