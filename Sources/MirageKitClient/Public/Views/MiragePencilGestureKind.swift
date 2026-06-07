//
//  MiragePencilGestureKind.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
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

/// Identifies a hardware gesture performed on Apple Pencil.
public enum MiragePencilGestureKind: String, CaseIterable, Codable, Sendable {
    /// Apple Pencil double-tap gesture.
    case doubleTap
    /// Apple Pencil squeeze gesture.
    case squeeze

    /// User-visible gesture name.
    public var displayName: String {
        switch self {
        case .doubleTap:
            "Double Tap"
        case .squeeze:
            "Squeeze"
        }
    }
}
