//
//  MirageDisplaySizePreset.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/24/26.
//
//  Client-selectable virtual display backing size for app streaming.
//

import Foundation

public enum MirageDisplaySizePreset: String, Sendable, CaseIterable, Codable, Equatable {
    /// iPad Pro 13-inch equivalent (2752x2064 @2x).
    case standard
    /// Vision Pro wide / 4K equivalent (3840x2160 @2x).
    case medium
    /// Studio Display / 5K equivalent (5120x2880 @2x).
    case large

    /// Pixel resolution for the shared virtual display at 2x Retina.
    public var pixelResolution: CGSize {
        switch self {
        case .standard:
            CGSize(width: 2752, height: 2064)
        case .medium:
            CGSize(width: 3840, height: 2160)
        case .large:
            CGSize(width: 5120, height: 2880)
        }
    }

    /// Logical resolution (pixel / 2) for the shared virtual display.
    public var logicalResolution: CGSize {
        let px = pixelResolution
        return CGSize(width: px.width / 2, height: px.height / 2)
    }

    public var displayName: String {
        switch self {
        case .standard:
            "Standard"
        case .medium:
            "Medium"
        case .large:
            "Large"
        }
    }

    public var subtitle: String {
        switch self {
        case .standard:
            "Best for iPad"
        case .medium:
            "Best for Apple Vision Pro and Mac"
        case .large:
            "Best for large or high-resolution displays"
        }
    }
}
