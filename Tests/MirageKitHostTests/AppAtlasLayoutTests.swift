//
//  AppAtlasLayoutTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import MirageKit
import Testing

@Suite("App Atlas Layout")
struct AppAtlasLayoutTests {

    @Test("Native atlas canvas aligns to encoded dimensions without expanding public regions")
    func nativeAtlasCanvasAlignsToEncodedDimensionsWithoutExpandingPublicRegions() throws {
        let layout = AppAtlasLayout.nativePackedLayout(
            windows: [
                AppAtlasLayout.Window(id: 501, sourceRect: CGRect(x: 0, y: 0, width: 2050, height: 1792)),
                AppAtlasLayout.Window(id: 502, sourceRect: CGRect(x: 0, y: 0, width: 2088, height: 1696)),
            ],
            spacing: 0
        )

        #expect(Int(layout.canvasSize.width) % 16 == 0)
        #expect(Int(layout.canvasSize.height) % 16 == 0)

        let publicLayout = layout.makePublicLayout(mediaStreamID: 91, layoutEpoch: 3)
        for region in publicLayout.regions {
            #expect(region.x >= 0)
            #expect(region.y >= 0)
            #expect(region.x + region.width <= publicLayout.width)
            #expect(region.y + region.height <= publicLayout.height)
        }

        let firstRegion = try #require(publicLayout.region(for: 501))
        let secondRegion = try #require(publicLayout.region(for: 502))
        #expect(firstRegion.pixelRect.size == CGSize(width: 2050, height: 1792))
        #expect(secondRegion.pixelRect.size == CGSize(width: 2088, height: 1696))
    }

    @Test("Canvas point maps back to source window coordinates")
    func canvasPointMapsBackToSourceWindowCoordinates() throws {
        let layout = AppAtlasLayout.fixedCanvasLayout(
            windows: [
                AppAtlasLayout.Window(id: 11, sourceRect: CGRect(x: 100, y: 200, width: 3840, height: 2160)),
                AppAtlasLayout.Window(id: 12, sourceRect: CGRect(x: 0, y: 0, width: 3840, height: 2160)),
            ],
            canvasSize: CGSize(width: 3840, height: 2160)
        )

        let mapped = try #require(layout.sourcePoint(forCanvasPoint: CGPoint(x: 960, y: 1080)))
        #expect(mapped.windowID == 11)
        #expect(mapped.point == CGPoint(x: 2020, y: 1280))
    }

    @Test("Public atlas layout preserves media identity epoch and focused region")
    func publicAtlasLayoutPreservesMediaIdentityEpochAndFocusedRegion() throws {
        let result = AppAtlasLayout.fixedCanvasLayout(
            windows: [
                AppAtlasLayout.Window(id: 31, sourceRect: CGRect(x: 0, y: 0, width: 3840, height: 2160)),
                AppAtlasLayout.Window(id: 32, sourceRect: CGRect(x: 0, y: 0, width: 3840, height: 2160)),
            ],
            canvasSize: CGSize(width: 3840, height: 2160)
        )

        let layout = result.makePublicLayout(
            mediaStreamID: 55,
            layoutEpoch: 7,
            focusedWindowID: 32
        )

        #expect(layout.mediaStreamID == 55)
        #expect(layout.layoutEpoch == 7)
        #expect(layout.canvasSize == CGSize(width: 3840, height: 2160))
        let firstRegion = try #require(layout.region(for: 31))
        let focusedRegion = try #require(layout.region(for: 32))
        #expect(firstRegion.pixelRect == CGRect(x: 0, y: 540, width: 1920, height: 1080))
        #expect(firstRegion.normalizedRect(in: layout) == CGRect(x: 0, y: 0.25, width: 0.5, height: 0.5))
        #expect(!firstRegion.isFocused)
        #expect(focusedRegion.isFocused)
    }

    @Test("Parent atlas layout stays stable for parent-local overlays")
    func parentAtlasLayoutStaysStableForParentLocalOverlays() {
        let parentWindow = AppAtlasLayout.Window(
            id: 71,
            sourceRect: CGRect(x: 0, y: 0, width: 1600, height: 1200)
        )
        let before = AppAtlasLayout.nativePackedLayout(windows: [parentWindow])
        _ = AppAtlasMediaCoordinator.auxiliaryOverlayDestinationRect(
            parentFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            parentSourceRect: parentWindow.sourceRect,
            auxiliaryFrame: CGRect(x: 600, y: 300, width: 180, height: 120)
        )
        let after = AppAtlasLayout.nativePackedLayout(windows: [parentWindow])

        #expect(after == before)
        #expect(after.placements.map(\.windowID) == [71])
    }
}
#endif
