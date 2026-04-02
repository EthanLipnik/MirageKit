//
//  MirageResolvedPointerLockState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

import Foundation

public struct MirageResolvedPointerLockState: Equatable, Sendable {
    public var isSupported: Bool
    public var isLocked: Bool

    public init(isSupported: Bool, isLocked: Bool) {
        self.isSupported = isSupported
        self.isLocked = isLocked
    }

    public static let unavailable = MirageResolvedPointerLockState(
        isSupported: false,
        isLocked: false
    )
}
