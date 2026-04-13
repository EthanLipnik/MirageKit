//
//  MirageClientStreamOptions.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

import Foundation

/// Controls where the client surfaces its stream options while streaming.
public enum MirageStreamOptionsDisplayMode: String, CaseIterable, Codable, Sendable {
    case inStream
    case hostMenuBar

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
    case on
    case secondaryOnly = "secondary_only"
    case off

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
