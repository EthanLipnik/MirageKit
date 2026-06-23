//
//  MirageClientStreamOptions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

/// Controls where the client surfaces its stream options while streaming.
public enum MirageStreamOptionsDisplayMode: String, CaseIterable, Codable, Sendable {
    /// Show stream controls as an overlay inside the stream surface.
    case inStream

    /// Move stream controls into the mirrored host menu bar when available.
    case hostMenuBar

    /// User-facing label for stream options settings.
    public var displayName: String {
        switch self {
        case .inStream:
            "Command Bar"
        case .hostMenuBar:
            "Host Menu Bar"
        }
    }
}

/// Controls which desktop stream types lock the client's local cursor.
public enum MirageDesktopCursorLockMode: String, CaseIterable, Codable, Sendable {
    /// Lock the local cursor for every desktop stream mode.
    case on

    /// Lock the local cursor only for dedicated secondary-display streams.
    case secondaryOnly = "secondary_only"

    /// Never lock the local cursor automatically.
    case off

    /// User-facing label for Lock Client Cursor settings.
    public var displayName: String {
        switch self {
        case .on:
            "On"
        case .secondaryOnly:
            "Secondary Only"
        case .off:
            "Off"
        }
    }

    /// User-facing explanation for Lock Client Cursor settings.
    public var footerDescription: String {
        let summary = switch self {
        case .on:
            "Desktop streams lock the client cursor."
        case .secondaryOnly:
            "Secondary displays lock the client cursor."
        case .off:
            "Desktop streams leave the client cursor unlocked."
        }

        let appStreamNote = "App streams never lock the client cursor."

        guard self != .off else {
            return summary + " " + appStreamNote
        }

        return summary
            + " "
            + appStreamNote
            + " Mirage unlocks the client cursor if relative mouse input is unavailable."
    }

    /// Returns whether this policy locks the local cursor for a desktop stream mode.
    public func locksClientCursor(for mode: MirageDesktopStreamMode) -> Bool {
        switch self {
        case .on:
            true
        case .secondaryOnly:
            mode == .secondary
        case .off:
            false
        }
    }
}
