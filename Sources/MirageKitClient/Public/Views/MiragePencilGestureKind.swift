//
//  MiragePencilGestureKind.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

import Foundation

/// Identifies a hardware gesture performed on Apple Pencil.
public enum MiragePencilGestureKind: String, CaseIterable, Codable, Sendable {
    case doubleTap
    case squeeze

    public var displayName: String {
        switch self {
        case .doubleTap:
            "Double Tap"
        case .squeeze:
            "Squeeze"
        }
    }
}
