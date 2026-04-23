//
//  DesktopVirtualDisplayResolutionFallbackTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/22/26.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Virtual Display Resolution Fallback")
struct DesktopVirtualDisplayResolutionFallbackTests {
    @Test("Live display mode wins over stale snapshots")
    func liveDisplayModeWinsOverStaleSnapshots() {
        let resolved = resolvedDesktopVirtualDisplayResolution(
            livePixelResolution: CGSize(width: 3024, height: 1964),
            sharedSnapshotResolution: CGSize(width: 1984, height: 2192),
            streamSnapshotResolution: CGSize(width: 1984, height: 2192),
            cachedResolution: CGSize(width: 1984, height: 2192)
        )

        #expect(resolved == CGSize(width: 3024, height: 1964))
    }

    @Test("Resolution fallback skips invalid candidates in precedence order")
    func resolutionFallbackSkipsInvalidCandidatesInPrecedenceOrder() {
        let sharedResolved = resolvedDesktopVirtualDisplayResolution(
            livePixelResolution: .zero,
            sharedSnapshotResolution: CGSize(width: 2560, height: 1600),
            streamSnapshotResolution: CGSize(width: 1984, height: 2192),
            cachedResolution: CGSize(width: 1728, height: 1117)
        )
        let streamResolved = resolvedDesktopVirtualDisplayResolution(
            livePixelResolution: nil,
            sharedSnapshotResolution: CGSize(width: -1, height: 1600),
            streamSnapshotResolution: CGSize(width: 1984, height: 2192),
            cachedResolution: CGSize(width: 1728, height: 1117)
        )
        let cachedResolved = resolvedDesktopVirtualDisplayResolution(
            livePixelResolution: nil,
            sharedSnapshotResolution: nil,
            streamSnapshotResolution: nil,
            cachedResolution: CGSize(width: 1728, height: 1117),
            fallbackResolution: CGSize(width: 1024, height: 768)
        )

        #expect(sharedResolved == CGSize(width: 2560, height: 1600))
        #expect(streamResolved == CGSize(width: 1984, height: 2192))
        #expect(cachedResolved == CGSize(width: 1728, height: 1117))
    }
}
#endif
