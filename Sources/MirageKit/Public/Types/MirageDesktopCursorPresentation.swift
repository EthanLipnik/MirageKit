import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
//
//  MirageWire.MirageDesktopCursorPresentation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//



/// Cursor source choices for desktop streams.
public extension MirageWire.MirageDesktopCursorSource {
    /// User-facing label for cursor source settings.
    var displayName: String {
        switch self {
        case .client:
            "Client"
        case .simulated:
            "Simulated"
        case .host:
            "Host"
        }
    }

    /// Short explanatory text for settings footers and menus.
    var footerDescription: String {
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
public extension MirageWire.MirageDesktopCursorPresentation {
    /// Whether the user can toggle cursor locking for the current source and desktop stream mode.
    func canToggleLockClientCursor(for mode: MirageMedia.MirageDesktopStreamMode) -> Bool {
        switch source {
        case .client, .simulated:
            mode != .secondary
        case .host:
            true
        }
    }

    /// Whether the client should currently lock the local cursor for this desktop stream mode.
    func locksClientCursor(for mode: MirageMedia.MirageDesktopStreamMode) -> Bool {
        switch source {
        case .client, .simulated:
            mode == .secondary || lockClientCursorWhenUsingMirageCursor
        case .host:
            lockClientCursorWhenUsingHostCursor
        }
    }
}
