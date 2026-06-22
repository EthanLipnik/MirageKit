//
//  MirageDisplaySizePreset.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//
//  Client-selectable virtual display backing size for app streaming.
//

import CoreGraphics

/// Client-selectable virtual display backing size for app streaming.
public enum MirageDisplaySizePreset: String, Sendable, CaseIterable, Codable, Equatable {
    /// UserDefaults key for the selected app-stream backing size preset.
    public static let defaultsKey = "streamSizePreset"

    /// iPad Pro 13-inch equivalent (2752x2064 @2x).
    case standard
    /// Mac 16:10 equivalent (3840x2400 @2x).
    case medium
    /// Studio Display / 5K equivalent (5120x2880 @2x).
    case large

    /// Pixel resolution for the shared virtual display at 2x Retina.
    public var pixelResolution: CGSize {
        switch self {
        case .standard:
            CGSize(width: 2752, height: 2064)
        case .medium:
            CGSize(width: 3840, height: 2400)
        case .large:
            CGSize(width: 5120, height: 2880)
        }
    }

    /// Width-to-height aspect ratio for this preset's backing pixel resolution.
    public var contentAspectRatio: CGFloat {
        let resolution = pixelResolution
        guard resolution.width > 0, resolution.height > 0 else { return 1 }
        return resolution.width / resolution.height
    }

    /// Logical resolution (pixel / 2) for the shared virtual display.
    public var logicalResolution: CGSize {
        let px = pixelResolution
        return CGSize(width: px.width / 2, height: px.height / 2)
    }

    /// User-facing preset name.
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

    /// Short guidance describing the displays this preset targets.
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

    /// Settings footer text describing the app-stream scale target.
    public var footerDescription: String {
        switch self {
        case .standard:
            "Scale app streams for an iPad-sized display."
        case .medium:
            "Scale app streams for a MacBook-sized display."
        case .large:
            "Scale app streams for a Studio Display-sized display."
        }
    }
}
