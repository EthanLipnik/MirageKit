//
//  MirageStreamLatencyMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation

/// Latency preference for stream buffering behavior.
public enum MirageStreamLatencyMode: String, Sendable, CaseIterable, Codable {
    /// Minimize buffering and presentation delay.
    case lowestLatency
    /// Favor smoother playback by allowing additional buffering.
    case smoothest

    /// Display label for stream settings UI.
    public var displayName: String {
        switch self {
        case .lowestLatency: "Lowest Latency"
        case .smoothest: "Smoothest"
        }
    }

    /// Detailed explanation suitable for settings UI.
    public var detailDescription: String {
        switch self {
        case .smoothest:
            "Targets steady visual cadence by presenting frames in order and dropping stale backlog when needed."
        case .lowestLatency:
            "Minimizes capture to encode to decode to display latency at all times using minimal buffering and immediate latest-frame presentation, even when FPS drops."
        }
    }
}
