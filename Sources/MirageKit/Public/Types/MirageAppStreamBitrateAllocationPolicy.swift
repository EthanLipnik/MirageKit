//
//  MirageAppStreamBitrateAllocationPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Shared bitrate-allocation modes for multi-window app streaming.
//

/// Describes how a shared app-stream bitrate budget should be distributed
/// across concurrently visible app windows.
public enum MirageAppStreamBitrateAllocationPolicy: String, Codable, Sendable, CaseIterable {
    /// Split the shared bitrate budget evenly across all visible app windows.
    case splitEvenly
    /// Prioritize the currently active window and keep floor bandwidth for others.
    case prioritizeActiveWindow

    /// User-facing label for settings and diagnostics.
    public var displayName: String {
        switch self {
        case .splitEvenly:
            "Split Evenly"
        case .prioritizeActiveWindow:
            "Favor Active Window"
        }
    }
}
