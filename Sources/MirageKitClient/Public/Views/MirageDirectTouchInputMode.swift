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
    /// Direct touches move/click/drag the pointer.
    case normal

    /// Direct touches move a virtual cursor (trackpad-style).
    case dragCursor

    /// Direct touches only generate smooth native scroll events.
    case pencilBased

    public var displayName: String {
        switch self {
        case .normal: "Normal"
        case .dragCursor: "Drag Cursor"
        case .pencilBased: "Pencil-based (Scroll Only)"
        }
    }

    /// Resolves persisted mode values, including legacy keys.
    public static func fromPersistedRawValue(
        _ rawValue: String,
        enableVirtualTrackpad: Bool
    ) -> MirageDirectTouchInputMode {
        if let mode = MirageDirectTouchInputMode(rawValue: rawValue) {
            return mode
        }
        switch rawValue {
        case "direct":
            return .normal
        case "exclusive", "scrollOnly":
            return .pencilBased
        default:
            return enableVirtualTrackpad ? .dragCursor : .normal
        }
    }
}
