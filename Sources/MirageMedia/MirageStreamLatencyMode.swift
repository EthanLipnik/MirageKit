//
//  MirageStreamLatencyMode.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation

/// Latency preference for stream buffering behavior.
public enum MirageStreamLatencyMode: String, Sendable, CaseIterable, Codable {
    /// Minimize buffering and presentation delay.
    case lowestLatency
    /// Keep latency close to immediate presentation while smoothing one-tick jitter.
    case balanced
    /// Favor smoother playback by allowing additional buffering.
    case smoothest

    /// Display label for stream settings UI.
    public var displayName: String {
        switch self {
        case .lowestLatency: "Most Responsive"
        case .balanced: "Balanced"
        case .smoothest: "Smoothest"
        }
    }

    /// Detailed explanation suitable for settings UI.
    public var detailDescription: String {
        switch self {
        case .balanced:
            "Keeps latency close to lowest-latency presentation while smoothing short receive jitter on display ticks."
        case .smoothest:
            "Targets steady visual cadence by presenting frames in order and dropping stale backlog when needed."
        case .lowestLatency:
            "Minimizes capture to encode to decode to display latency at all times using minimal buffering and immediate latest-frame presentation, even when FPS drops."
        }
    }
}
