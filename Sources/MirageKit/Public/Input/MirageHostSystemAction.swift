//
//  MirageHostSystemAction.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/11/26.
//

import Foundation

/// A host-owned system action that should resolve on the host at execution time.
public enum MirageHostSystemAction: UInt8, Codable, Sendable, Hashable {
    case spaceLeft = 1
    case spaceRight = 2
    case missionControl = 3
    case appExpose = 4
}

/// A request to execute a host-owned system action with an optional key fallback.
public struct MirageHostSystemActionRequest: Codable, Sendable, Hashable {
    public let action: MirageHostSystemAction
    public let fallbackKeyEvent: MirageKeyEvent?

    public init(
        action: MirageHostSystemAction,
        fallbackKeyEvent: MirageKeyEvent? = nil
    ) {
        self.action = action
        self.fallbackKeyEvent = fallbackKeyEvent
    }
}

public extension MirageAction {
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
