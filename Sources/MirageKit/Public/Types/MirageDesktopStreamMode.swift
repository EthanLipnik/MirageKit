//
//  MirageDesktopStreamMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/1/26.
//
//  Desktop stream mode selection for mirrored vs secondary display usage.
//

import Foundation

public enum MirageDesktopStreamMode: String, Sendable, CaseIterable, Codable {
    case mirrored
    case secondary

    public var displayName: String {
        switch self {
        case .mirrored:
            "Full Desktop"
        case .secondary:
            "Secondary Display"
        }
    }
}
