import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
//
//  MirageClientStreamOptions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//



/// Controls where the client surfaces its stream options while streaming.
public extension MirageWire.MirageStreamOptionsDisplayMode {
    /// User-facing label for stream options settings.
    var displayName: String {
        switch self {
        case .inStream:
            "Command Bar"
        case .hostMenuBar:
            "Host Menu Bar"
        }
    }
}


/// Controls which desktop stream types lock the client's local cursor.
public extension MirageWire.MirageDesktopCursorLockMode {
    /// User-facing label for cursor-lock settings.
    var displayName: String {
        switch self {
        case .on:
            "On"
        case .secondaryOnly:
            "Secondary Only"
        case .off:
            "Off"
        }
    }

    /// User-facing explanation for client cursor-lock settings.
    var footerDescription: String {
        let summary = switch self {
        case .on:
            "Desktop streams lock the cursor."
        case .secondaryOnly:
            "Secondary displays lock the cursor."
        case .off:
            "Desktop streams leave the cursor unlocked."
        }

        let appStreamNote = "App streams never lock the cursor."

        guard self != .off else {
            return summary + " " + appStreamNote
        }

        return summary
            + " "
            + appStreamNote
            + " Mirage unlocks the cursor if relative mouse input is unavailable."
    }

    /// Returns whether this policy locks the local cursor for a desktop stream mode.
    func locksClientCursor(for mode: MirageMedia.MirageDesktopStreamMode) -> Bool {
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
