//
//  DesktopDisplayBoundsResolutionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

import CoreGraphics
@testable import MirageKitHost
import Testing

@Suite("Desktop Display Bounds Resolution")
struct DesktopDisplayBoundsResolutionTests {
    @Test("Live secondary-display bounds override stale cached bounds")
    func liveBoundsOverrideCachedBounds() {
        let cachedBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let liveBounds = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

        let resolvedBounds = resolvedDesktopDisplayBounds(
            cachedBounds: cachedBounds,
            liveBounds: liveBounds,
            displayModeSize: nil,
            displayOrigin: liveBounds.origin
        )

        #expect(resolvedBounds == liveBounds)
    }

    @Test("Display mode fallback preserves the live display origin")
    func displayModeFallbackPreservesDisplayOrigin() {
        let cachedBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let liveBounds = CGRect(x: 3840, y: 0, width: 0, height: 0)
        let displayModeSize = CGSize(width: 2560, height: 1440)

        let resolvedBounds = resolvedDesktopDisplayBounds(
            cachedBounds: cachedBounds,
            liveBounds: liveBounds,
            displayModeSize: displayModeSize,
            displayOrigin: liveBounds.origin
        )

        #expect(resolvedBounds == CGRect(origin: liveBounds.origin, size: displayModeSize))
    }

    @Test("Cached bounds remain the final fallback when live geometry is unavailable")
    func cachedBoundsFallbackWhenLiveGeometryUnavailable() {
        let cachedBounds = CGRect(x: 2560, y: -900, width: 1920, height: 1080)

        let resolvedBounds = resolvedDesktopDisplayBounds(
            cachedBounds: cachedBounds,
            liveBounds: nil,
            displayModeSize: nil,
            displayOrigin: .zero
        )

        #expect(resolvedBounds == cachedBounds)
    }
}
