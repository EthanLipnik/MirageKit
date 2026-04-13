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
    /// Direct touches scroll natively; taps click; long press and two-finger drag perform left drag.
    case normal

    /// Simulated trackpad-style cursor movement.
    case dragCursor

    public var displayName: String {
        switch self {
        case .normal: "Direct"
        case .dragCursor: "Simulated Trackpad"
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
