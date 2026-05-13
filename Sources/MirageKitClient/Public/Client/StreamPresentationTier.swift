//
//  StreamPresentationTier.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/27/26.
//

/// Client presentation priority for an active stream.
public enum StreamPresentationTier: String, Codable, Sendable, Equatable {
    /// Stream should be presented as live interactive content.
    case activeLive
    /// Stream may be treated as passive snapshot content.
    case passiveSnapshot
}
