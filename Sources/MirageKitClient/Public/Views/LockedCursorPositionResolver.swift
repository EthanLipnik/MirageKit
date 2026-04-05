//
//  LockedCursorPositionResolver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/5/26.
//

import CoreGraphics

enum LockedCursorPositionResolver {
    static func resolve(_ position: CGPoint, allowsExtendedBounds: Bool) -> CGPoint {
        if allowsExtendedBounds { return position }
        return CGPoint(
            x: min(max(position.x, 0), 1),
            y: min(max(position.y, 0), 1)
        )
    }
}
