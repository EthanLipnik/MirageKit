//
//  MirageNetworkPathKind.swift
//  MirageCore
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Broad Mirage-owned classification for the active network path.
public enum MirageNetworkPathKind: String, Codable, Sendable, Equatable {
    case awdl
    case wifi
    case wired
    case cellular
    case vpn
    case loopback
    case other
    case unknown
}
