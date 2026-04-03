//
//  MiragePencilInputMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Apple Pencil input behavior options for iPad clients.
//

import Foundation

/// Determines how Apple Pencil input is translated into host pointer input.
public enum MiragePencilInputMode: String, CaseIterable, Codable, Sendable {
    /// Pencil follows touch-style mouse semantics (tap click, hold drag, squeeze secondary click).
    case mouse

    /// Pencil forwards tablet-style pressure and orientation metadata.
    case drawingTablet

    public var displayName: String {
        switch self {
        case .mouse: "Mouse"
        case .drawingTablet: "Drawing Tablet"
        }
    }
}
