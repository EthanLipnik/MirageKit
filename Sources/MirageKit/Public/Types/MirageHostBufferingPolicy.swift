//
//  MirageHostBufferingPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/18/26.
//

import Foundation

/// Host-side buffering policy for capture-to-encode freshness.
public enum MirageHostBufferingPolicy: String, Sendable, Codable {
    /// Preserve stability-biased buffering for difficult routes or capture paths.
    case stability
    /// Prefer the freshest captured frame and avoid Mirage-owned extra frame holds.
    case freshestFrame
}
