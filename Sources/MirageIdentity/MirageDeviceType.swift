//
//  MirageDeviceType.swift
//  MirageIdentity
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Broad Mirage device family for peer, host, and trust identity projections.
public enum MirageDeviceType: String, Sendable, Codable, Hashable, CaseIterable {
    case mac
    case iPad
    case iPhone
    case vision
    case unknown

    public var displayName: String {
        switch self {
        case .mac:
            "Mac"
        case .iPad:
            "iPad"
        case .iPhone:
            "iPhone"
        case .vision:
            "Apple Vision Pro"
        case .unknown:
            "Unknown"
        }
    }

    public var systemImage: String {
        switch self {
        case .mac:
            "desktopcomputer"
        case .iPad:
            "ipad"
        case .iPhone:
            "iphone"
        case .vision:
            "visionpro"
        case .unknown:
            "questionmark.circle"
        }
    }
}
