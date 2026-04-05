//
//  MirageDirectTouchInputMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Direct touch behavior options for iPad and visionOS clients.
//

import Foundation

/// Determines how direct screen touches are translated into host input.
public enum MirageDirectTouchInputMode: String, CaseIterable, Codable, Sendable {
    /// Single-finger touches scroll natively; taps click; long press and two-finger drag perform left drag.
    case normal

    /// Direct touches move a virtual cursor (trackpad-style).
    case dragCursor

    public var displayName: String {
        switch self {
        case .normal: "Normal"
        case .dragCursor: "Drag Cursor"
        }
    }

    /// Resolves persisted mode values.
    public static func fromPersistedRawValue(
        _ rawValue: String,
        enableVirtualTrackpad: Bool
    ) -> MirageDirectTouchInputMode {
        if let mode = MirageDirectTouchInputMode(rawValue: rawValue) {
            return mode
        }
        return enableVirtualTrackpad ? .dragCursor : .normal
    }
}
