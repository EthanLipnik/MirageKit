//
//  HostWallpaperResolutionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/29/26.
//
//  Host wallpaper sizing coverage.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Host Wallpaper Resolution")
struct HostWallpaperResolutionTests {
    @Test("Primary physical display is preferred when the main display is virtual")
    func primaryPhysicalDisplayPreferredWhenMainIsVirtual() {
        let displayID = MirageHostWallpaperResolver.resolvedPrimaryPhysicalDisplayID(
            mainDisplayID: 24,
            onlineDisplayIDs: [24, 7, 8],
            isVirtualDisplay: { $0 == 24 }
        )

        #expect(displayID == 7)
    }

    @Test("Wallpaper window selection matches the target display and ignores unrelated candidates")
    func wallpaperWindowSelectionMatchesDisplay() {
        let targetDisplayFrame = CGRect(x: 0, y: 0, width: 1_800, height: 1_200)
        let candidates = [
            MirageHostWallpaperResolver.WallpaperWindowCandidate(
                windowID: 10,
                ownerName: "Finder",
                title: "",
                frame: targetDisplayFrame,
                windowLayer: -1
            ),
            MirageHostWallpaperResolver.WallpaperWindowCandidate(
                windowID: 11,
                ownerName: "Dock",
                title: "Wallpaper-",
                frame: CGRect(x: 1_800, y: 0, width: 1_800, height: 1_200),
                windowLayer: -2_147_483_624
            ),
            MirageHostWallpaperResolver.WallpaperWindowCandidate(
                windowID: 12,
                ownerName: "Dock",
                title: "Wallpaper-",
                frame: targetDisplayFrame,
                windowLayer: -2_147_483_624
            ),
        ]

        let candidate = MirageHostWallpaperResolver.wallpaperWindowCandidate(
            from: candidates,
            for: targetDisplayFrame
        )

        #expect(candidate?.windowID == 12)
    }

    @Test("Wallpaper window selection accepts Dock wallpaper windows with nonnegative layers")
    func wallpaperWindowSelectionAcceptsNonnegativeLayer() {
        let targetDisplayFrame = CGRect(x: 0, y: 0, width: 1_800, height: 1_200)
        let candidates = [
            MirageHostWallpaperResolver.WallpaperWindowCandidate(
                windowID: 21,
                ownerName: "Dock",
                title: "Wallpaper-",
                frame: targetDisplayFrame,
                windowLayer: 0
            ),
        ]

        let candidate = MirageHostWallpaperResolver.wallpaperWindowCandidate(
            from: candidates,
            for: targetDisplayFrame
        )

        #expect(candidate?.windowID == 21)
    }

    @Test("Wallpaper window selection prefers desktop layers for equal overlap")
    func wallpaperWindowSelectionPrefersDesktopLayerForEqualOverlap() {
        let targetDisplayFrame = CGRect(x: 0, y: 0, width: 1_800, height: 1_200)
        let candidates = [
            MirageHostWallpaperResolver.WallpaperWindowCandidate(
                windowID: 31,
                ownerName: "Dock",
                title: "Wallpaper-",
                frame: targetDisplayFrame,
                windowLayer: 0
            ),
            MirageHostWallpaperResolver.WallpaperWindowCandidate(
                windowID: 32,
                ownerName: "Dock",
                title: "Wallpaper-",
                frame: targetDisplayFrame,
                windowLayer: -2_147_483_624
            ),
        ]

        let candidate = MirageHostWallpaperResolver.wallpaperWindowCandidate(
            from: candidates,
            for: targetDisplayFrame
        )

        #expect(candidate?.windowID == 32)
    }
}
#endif
