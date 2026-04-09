//
//  MirageDesktopStreamMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/1/26.
//
//  Desktop stream mode selection for unified vs secondary display usage.
//

import Foundation

public enum MirageDesktopStreamMode: String, Sendable, CaseIterable, Codable {
    case unified
    case secondary

    public var displayName: String {
        switch self {
        case .unified:
            "Unified"
        case .secondary:
            "Secondary Display"
        }
    }
}
