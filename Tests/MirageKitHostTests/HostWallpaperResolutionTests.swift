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

    @Test("Requested resolution acts as an upper bound")
    func requestedResolutionActsAsUpperBound() {
        let output = MirageHostWallpaperResolver.resolvedMaxOutputSize(
            sourcePixelWidth: 1_000,
            sourcePixelHeight: 600,
            preferredMaxPixelWidth: 854,
            preferredMaxPixelHeight: 480
        )

        #expect(output.width == 800)
        #expect(output.height == 480)
    }

    @Test("Large source is capped without forcing width when height is limiting")
    func largeSourceIsCappedByLimitingAxis() {
        let output = MirageHostWallpaperResolver.resolvedMaxOutputSize(
            sourcePixelWidth: 5_120,
            sourcePixelHeight: 3_200,
            preferredMaxPixelWidth: 854,
            preferredMaxPixelHeight: 480
        )

        #expect(output.width == 768)
        #expect(output.height == 480)
    }

    @Test("Host wallpaper request size clamps to 480p bounds")
    func hostWallpaperRequestSizeClampsTo480pBounds() {
        let low = MirageHostWallpaperResolver.clampedRequestedOutputSize(
            preferredMaxPixelWidth: 100,
            preferredMaxPixelHeight: 100
        )
        let high = MirageHostWallpaperResolver.clampedRequestedOutputSize(
            preferredMaxPixelWidth: 3_840,
            preferredMaxPixelHeight: 2_160
        )

        #expect(low.width == 427)
        #expect(low.height == 240)
        #expect(high.width == 854)
        #expect(high.height == 480)
    }

    @Test("Wallpaper transfer metadata uses JPEG")
    func wallpaperTransferMetadataUsesJPEG() {
        #expect(MirageHostWallpaperResolver.encodedFileExtension == "jpg")
        #expect(MirageHostWallpaperResolver.encodedContentType == "image/jpeg")
        #expect(MirageHostWallpaperResolver.encodedCompressionQuality == 0.5)
    }
}
#endif
