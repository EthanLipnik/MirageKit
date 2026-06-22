//
//  MirageMediaStrategy.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Media pipeline family selected for a stream recipe.
public enum MirageMediaStrategy: String, Sendable, Codable, Equatable, CaseIterable {
    /// Current full-frame HEVC path.
    case fullFrameHEVC

    /// Current app-window atlas path.
    case appAtlas

    /// Caller-defined custom media path.
    case custom
}
