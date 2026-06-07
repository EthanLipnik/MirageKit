//
//  MirageHostBufferingPolicy.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Host-side buffering policy for capture-to-encode freshness.
public enum MirageHostBufferingPolicy: String, Sendable, Codable {
    /// Preserve stability-biased buffering for difficult routes or capture paths.
    case stability
    /// Prefer the freshest captured frame and avoid Mirage-owned extra frame holds.
    case freshestFrame
}
