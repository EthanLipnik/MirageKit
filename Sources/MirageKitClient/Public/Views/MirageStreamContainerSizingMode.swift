import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
//
//  MirageStreamContainerSizingMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

/// Selects the client-side bounds source used for window-driven stream resizing.
public enum MirageStreamContainerSizingMode: Sendable, Equatable {
    /// Use the platform content layout area when available.
    case contentLayout
    /// Use the actual stream view bounds.
    case viewBounds
}
