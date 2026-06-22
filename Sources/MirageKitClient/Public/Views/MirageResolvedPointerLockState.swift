//
//  MirageResolvedPointerLockState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

/// Current pointer-lock capability and lock state for the active client scene.
public struct MirageResolvedPointerLockState: Equatable, Sendable {
    /// Whether the current platform and input environment can support pointer lock.
    public var isSupported: Bool
    /// Whether pointer lock is currently active.
    public var isLocked: Bool

    /// Creates a resolved pointer-lock state.
    public init(isSupported: Bool, isLocked: Bool) {
        self.isSupported = isSupported
        self.isLocked = isLocked
    }

    /// State used when pointer lock is unavailable on the current platform or scene.
    public static let unavailable = MirageResolvedPointerLockState(
        isSupported: false,
        isLocked: false
    )
}
