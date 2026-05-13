//
//  MirageDesktopStreamMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/1/26.
//
//  Desktop stream mode selection for unified vs secondary display usage.
//

/// Desktop streaming topology requested by the client.
public enum MirageDesktopStreamMode: String, Sendable, CaseIterable, Codable {
    /// Stream the host's unified desktop workspace.
    case unified
    /// Stream a dedicated secondary virtual display.
    case secondary

    /// User-facing display name for settings and menus.
    public var displayName: String {
        switch self {
        case .unified:
            "Unified"
        case .secondary:
            "Secondary Display"
        }
    }
}
