//
//  MirageHostSystemAction.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/11/26.
//

import Foundation

/// A host-owned system action that should resolve on the host at execution time.
public enum MirageHostSystemAction: UInt8, Codable, Sendable, Hashable {
    /// Move the active desktop space to the left.
    case spaceLeft = 1
    /// Move the active desktop space to the right.
    case spaceRight = 2
    /// Open Mission Control.
    case missionControl = 3
    /// Open App Expose for the active app.
    case appExpose = 4
}

/// A request to execute a host-owned system action with an optional key fallback.
public struct MirageHostSystemActionRequest: Codable, Sendable, Hashable {
    /// Host-side system action to resolve and execute.
    public let action: MirageHostSystemAction

    /// Optional synthetic key event to use when the host system action path is unavailable.
    public let fallbackKeyEvent: MirageKeyEvent?

    /// Creates a host system-action request.
    public init(
        action: MirageHostSystemAction,
        fallbackKeyEvent: MirageKeyEvent? = nil
    ) {
        self.action = action
        self.fallbackKeyEvent = fallbackKeyEvent
    }
}

public extension MirageAction {
    /// Host system-action request represented by this shortcut action, when applicable.
    var hostSystemActionRequest: MirageHostSystemActionRequest? {
        let hostSystemAction: MirageHostSystemAction
        switch id {
        case Self.spaceLeftID:
            hostSystemAction = .spaceLeft
        case Self.spaceRightID:
            hostSystemAction = .spaceRight
        case Self.missionControlID:
            hostSystemAction = .missionControl
        case Self.appExposeID:
            hostSystemAction = .appExpose
        default:
            return nil
        }

        return MirageHostSystemActionRequest(
            action: hostSystemAction,
            fallbackKeyEvent: hostKeyEvent
        )
    }
}
