//
//  DesktopDisplayTopologyResolution.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import CoreGraphics
import Foundation

/// Result of refreshing desktop input geometry after display topology changes.
struct DesktopInputGeometryRefreshResult: Equatable {
    let virtualResolution: CGSize?
    let inputBounds: CGRect
}

/// Resolves the best available desktop display bounds from live, mode, or cached geometry.
func resolvedDesktopDisplayBounds(
    cachedBounds: CGRect?,
    liveBounds: CGRect?,
    displayModeSize: CGSize?,
    displayOrigin: CGPoint
)
-> CGRect? {
    if let liveBounds, liveBounds.width > 0, liveBounds.height > 0 {
        return liveBounds
    }

    if let displayModeSize,
       displayModeSize.width > 0,
       displayModeSize.height > 0 {
        return CGRect(origin: displayOrigin, size: displayModeSize)
    }

    if let cachedBounds, cachedBounds.width > 0, cachedBounds.height > 0 {
        return cachedBounds
    }

    return nil
}

/// Returns a positive virtual resolution, or nil for missing or invalid values.
func validDesktopVirtualResolution(_ resolution: CGSize?) -> CGSize? {
    guard let resolution,
          resolution.width > 0,
          resolution.height > 0 else {
        return nil
    }
    return resolution
}

/// Chooses the most authoritative desktop virtual-display pixel resolution.
func resolvedDesktopVirtualDisplayResolution(
    livePixelResolution: CGSize?,
    sharedSnapshotResolution: CGSize?,
    streamSnapshotResolution: CGSize?,
    cachedResolution: CGSize?,
    fallbackResolution: CGSize? = nil
)
-> CGSize? {
    validDesktopVirtualResolution(livePixelResolution) ??
        validDesktopVirtualResolution(sharedSnapshotResolution) ??
        validDesktopVirtualResolution(streamSnapshotResolution) ??
        validDesktopVirtualResolution(cachedResolution) ??
        validDesktopVirtualResolution(fallbackResolution)
}

/// Returns true when two virtual resolutions differ beyond the resize tolerance.
func desktopVirtualResolutionChanged(
    from previousResolution: CGSize?,
    to nextResolution: CGSize?,
    tolerance: CGFloat = 1
)
-> Bool {
    guard let previousResolution = validDesktopVirtualResolution(previousResolution),
          let nextResolution = validDesktopVirtualResolution(nextResolution) else {
        return validDesktopVirtualResolution(previousResolution) != validDesktopVirtualResolution(nextResolution)
    }

    return abs(previousResolution.width - nextResolution.width) > tolerance ||
        abs(previousResolution.height - nextResolution.height) > tolerance
}
