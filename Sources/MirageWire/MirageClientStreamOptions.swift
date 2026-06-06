//
//  MirageClientStreamOptions.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Controls where the client surfaces its stream options while streaming.
public enum MirageStreamOptionsDisplayMode: String, CaseIterable, Codable, Sendable {
    /// Show stream controls as an overlay inside the stream surface.
    case inStream

    /// Move stream controls into the mirrored host menu bar when available.
    case hostMenuBar
}

/// Controls which desktop stream types lock the client's local cursor.
public enum MirageDesktopCursorLockMode: String, CaseIterable, Codable, Sendable {
    /// Lock the local cursor for every desktop stream mode.
    case on

    /// Lock the local cursor only for dedicated secondary-display streams.
    case secondaryOnly = "secondary_only"

    /// Never lock the local cursor automatically.
    case off
}

/// Cursor source choices for desktop streams.
public enum MirageDesktopCursorSource: String, Codable, Sendable, CaseIterable, Hashable {
    /// Show the local client cursor instead of capturing the host cursor in the stream.
    case client

    /// Render Mirage's software cursor instead of capturing the host cursor in the stream.
    case simulated

    /// Capture and display the real host cursor inside the streamed desktop image.
    case host
}

/// Cursor presentation configuration for desktop streams.
public struct MirageDesktopCursorPresentation: Codable, Equatable, Sendable, Hashable {
    /// Which cursor source should be visible to the user.
    public var source: MirageDesktopCursorSource

    /// Whether the client should lock and hide its local cursor when Mirage renders the local cursor.
    public var lockClientCursorWhenUsingMirageCursor: Bool

    /// Whether the client should lock and hide its local cursor when the host cursor is captured.
    public var lockClientCursorWhenUsingHostCursor: Bool

    /// Creates a desktop cursor presentation policy with Mirage-overlay defaults.
    public init(
        source: MirageDesktopCursorSource = .simulated,
        lockClientCursorWhenUsingMirageCursor: Bool = false,
        lockClientCursorWhenUsingHostCursor: Bool = true
    ) {
        self.source = source
        self.lockClientCursorWhenUsingMirageCursor = lockClientCursorWhenUsingMirageCursor
        self.lockClientCursorWhenUsingHostCursor = lockClientCursorWhenUsingHostCursor
    }

    /// Default desktop cursor presentation, using Mirage's synthetic cursor overlay.
    public static let simulatedCursor = MirageDesktopCursorPresentation()

    /// Whether the host should capture the real macOS cursor into the desktop stream.
    public var capturesHostCursor: Bool {
        source == .host
    }

    /// Whether the client should render Mirage's synthetic cursor overlay.
    public var rendersSyntheticClientCursor: Bool {
        source == .simulated
    }

    /// Whether the host needs to send cursor position updates for this presentation mode.
    public var requiresCursorPositionUpdates: Bool {
        source != .simulated
    }

    /// Whether the client should hide its local system cursor while streaming.
    public var hidesLocalCursor: Bool {
        switch source {
        case .client:
            false
        case .simulated, .host:
            true
        }
    }

    /// Returns the stored cursor-lock preference for the supplied source, or the active source.
    public func lockClientCursorPreference(for source: MirageDesktopCursorSource? = nil) -> Bool {
        switch source ?? self.source {
        case .client, .simulated:
            lockClientCursorWhenUsingMirageCursor
        case .host:
            lockClientCursorWhenUsingHostCursor
        }
    }

    /// Updates the cursor-lock preference for the supplied source, or the active source.
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
}
