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
    case client = "local"

    /// Render Mirage's software cursor instead of capturing the host cursor in the stream.
    case emulated = "client"

    /// Capture and display the real host cursor inside the streamed desktop image.
    case host

    public var displayName: String {
        switch self {
        case .client:
            "Client"
        case .emulated:
            "Emulated"
        case .host:
            "Host"
        }
    }

    public var footerDescription: String {
        switch self {
        case .client:
            "Client uses your local cursor."
        case .emulated:
            "Emulated draws Mirage's software cursor."
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
        source: MirageDesktopCursorSource = .emulated,
        lockClientCursorWhenUsingMirageCursor: Bool = false,
        lockClientCursorWhenUsingHostCursor: Bool = true
    ) {
        self.source = source
        self.lockClientCursorWhenUsingMirageCursor = lockClientCursorWhenUsingMirageCursor
        self.lockClientCursorWhenUsingHostCursor = lockClientCursorWhenUsingHostCursor
    }

    /// Default desktop cursor presentation.
    public static let emulatedCursor = MirageDesktopCursorPresentation()

    public var capturesHostCursor: Bool {
        source == .host
    }

    public var rendersSyntheticClientCursor: Bool {
        source == .emulated
    }

    public var requiresCursorPositionUpdates: Bool {
        source != .emulated
    }

    public func lockClientCursorPreference(for source: MirageDesktopCursorSource? = nil) -> Bool {
        switch source ?? self.source {
        case .client, .emulated:
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
        case .client, .emulated:
            lockClientCursorWhenUsingMirageCursor = isEnabled
        case .host:
            lockClientCursorWhenUsingHostCursor = isEnabled
        }
    }

    public func canToggleLockClientCursor(for mode: MirageDesktopStreamMode) -> Bool {
        switch source {
        case .client, .emulated:
            mode != .secondary
        case .host:
            true
        }
    }

    public func locksClientCursor(for mode: MirageDesktopStreamMode) -> Bool {
        switch source {
        case .client, .emulated:
            mode == .secondary || lockClientCursorWhenUsingMirageCursor
        case .host:
            lockClientCursorWhenUsingHostCursor
        }
    }
}
