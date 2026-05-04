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
    @Test("Native atlas keeps one window region at exact captured size")
    func nativeAtlasKeepsOneWindowRegionAtExactCapturedSize() {
        let layout = AppAtlasLayout.nativePackedLayout(
            windows: [
                AppAtlasLayout.Window(id: 101, sourceRect: CGRect(x: 0, y: 0, width: 1234, height: 926)),
            ]
        )

        #expect(layout.canvasSize == CGSize(width: 1248, height: 928))
        #expect(layout.placements.count == 1)
        #expect(layout.placements[0].sourceRect == CGRect(x: 0, y: 0, width: 1234, height: 926))
        #expect(layout.placements[0].destinationRect == CGRect(x: 0, y: 0, width: 1234, height: 926))
    }

    @Test("Native atlas publishes content-sized region for cropped source")
    func nativeAtlasPublishesContentSizedRegionForCroppedSource() throws {
        let layout = AppAtlasLayout.nativePackedLayout(
            windows: [
                AppAtlasLayout.Window(id: 301, sourceRect: CGRect(x: 20, y: 40, width: 640, height: 400)),
            ]
        )

        #expect(layout.canvasSize == CGSize(width: 640, height: 400))
        #expect(layout.placements.count == 1)
        #expect(layout.placements[0].sourceRect == CGRect(x: 20, y: 40, width: 640, height: 400))
        #expect(layout.placements[0].destinationRect == CGRect(x: 0, y: 0, width: 640, height: 400))

        let publicLayout = layout.makePublicLayout(mediaStreamID: 77, layoutEpoch: 1)
        let region = try #require(publicLayout.region(for: 301))
        #expect(region.pixelRect == CGRect(x: 0, y: 0, width: 640, height: 400))
    }

    @Test("Native atlas packs multiple windows without scaling")
    func nativeAtlasPacksMultipleWindowsWithoutScaling() {
        let layout = AppAtlasLayout.nativePackedLayout(
            windows: [
                AppAtlasLayout.Window(id: 201, sourceRect: CGRect(x: 0, y: 0, width: 640, height: 400)),
                AppAtlasLayout.Window(id: 202, sourceRect: CGRect(x: 0, y: 0, width: 320, height: 600)),
                AppAtlasLayout.Window(id: 203, sourceRect: CGRect(x: 0, y: 0, width: 480, height: 300)),
            ],
            spacing: 0
        )

        #expect(layout.canvasSize == CGSize(width: 800, height: 1008))
        #expect(layout.placements.map(\.windowID) == [201, 202, 203])
        #expect(layout.placements[0].destinationRect == CGRect(x: 0, y: 0, width: 640, height: 400))
        #expect(layout.placements[1].destinationRect == CGRect(x: 0, y: 400, width: 320, height: 600))
        #expect(layout.placements[2].destinationRect == CGRect(x: 320, y: 400, width: 480, height: 300))
        #expect(layout.placements[0].sourceRect.size == layout.placements[0].destinationRect.size)
        #expect(layout.placements[1].sourceRect.size == layout.placements[1].destinationRect.size)
        #expect(layout.placements[2].sourceRect.size == layout.placements[2].destinationRect.size)
    }

    @Test("Native atlas preserves source rects while public regions stay destinations")
    func nativeAtlasPreservesSourceRectsWhilePublicRegionsStayDestinations() throws {
        let layout = AppAtlasLayout.nativePackedLayout(
            windows: [
                AppAtlasLayout.Window(id: 401, sourceRect: CGRect(x: 12, y: 16, width: 640, height: 400)),
                AppAtlasLayout.Window(id: 402, sourceRect: CGRect(x: 30, y: 44, width: 320, height: 600)),
            ],
            spacing: 0
        )

        #expect(layout.placements.map(\.windowID) == [401, 402])
        #expect(layout.placements[0].sourceRect == CGRect(x: 12, y: 16, width: 640, height: 400))
        #expect(layout.placements[1].sourceRect == CGRect(x: 30, y: 44, width: 320, height: 600))
        #expect(layout.placements[0].destinationRect == CGRect(x: 0, y: 0, width: 640, height: 400))
        #expect(layout.placements[1].destinationRect == CGRect(x: 640, y: 0, width: 320, height: 600))

        let publicLayout = layout.makePublicLayout(mediaStreamID: 88, layoutEpoch: 2)
        let firstRegion = try #require(publicLayout.region(for: 401))
        let secondRegion = try #require(publicLayout.region(for: 402))
        #expect(firstRegion.pixelRect == layout.placements[0].destinationRect)
        #expect(secondRegion.pixelRect == layout.placements[1].destinationRect)
    }

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

    @Test("Coordinator source rect normalization clamps to capture bounds")
    func coordinatorSourceRectNormalizationClampsToCaptureBounds() {
        let pixelSize = CGSize(width: 200, height: 100)

        #expect(
            AppAtlasMediaCoordinator.normalizedSourceRect(
                contentRect: CGRect(x: 10.2, y: 19.7, width: 400, height: 300),
                pixelSize: pixelSize
            ) == CGRect(x: 10, y: 19, width: 190, height: 81)
        )
        #expect(
            AppAtlasMediaCoordinator.normalizedSourceRect(
                contentRect: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
                pixelSize: pixelSize
            ) == CGRect(x: 0, y: 0, width: 200, height: 100)
        )
    }

    @Test("Two large windows scale into one stable canvas row")
    func twoLargeWindowsScaleIntoOneStableCanvasRow() {
        let layout = AppAtlasLayout.fixedCanvasLayout(
            windows: [
                AppAtlasLayout.Window(id: 1, sourceRect: CGRect(x: 0, y: 0, width: 3840, height: 2160)),
                AppAtlasLayout.Window(id: 2, sourceRect: CGRect(x: 0, y: 0, width: 3840, height: 2160)),
            ],
            canvasSize: CGSize(width: 3840, height: 2160)
        )

        #expect(layout.canvasSize == CGSize(width: 3840, height: 2160))
        #expect(layout.contentRect == CGRect(x: 0, y: 540, width: 3840, height: 1080))
        #expect(layout.placements.map(\.windowID) == [1, 2])
        #expect(layout.placements[0].destinationRect == CGRect(x: 0, y: 540, width: 1920, height: 1080))
        #expect(layout.placements[1].destinationRect == CGRect(x: 1920, y: 540, width: 1920, height: 1080))
    }

    @Test("Four matching windows pack into a full fixed canvas grid")
    func fourMatchingWindowsPackIntoFullFixedCanvasGrid() {
        let layout = AppAtlasLayout.fixedCanvasLayout(
            windows: (1 ... 4).map { windowID in
                AppAtlasLayout.Window(
                    id: WindowID(windowID),
                    sourceRect: CGRect(x: 0, y: 0, width: 3840, height: 2160)
                )
            },
            canvasSize: CGSize(width: 3840, height: 2160)
        )

        #expect(layout.contentRect == CGRect(x: 0, y: 0, width: 3840, height: 2160))
        #expect(layout.placements.map(\.destinationRect) == [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),
            CGRect(x: 1920, y: 1080, width: 1920, height: 1080),
        ])
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

    @Test("Invalid windows are ignored")
    func invalidWindowsAreIgnored() {
        let layout = AppAtlasLayout.fixedCanvasLayout(
            windows: [
                AppAtlasLayout.Window(id: 21, sourceRect: CGRect(x: 0, y: 0, width: 0, height: 2160)),
                AppAtlasLayout.Window(id: 22, sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            ],
            canvasSize: CGSize(width: 1920, height: 1080)
        )

        #expect(layout.placements.map(\.windowID) == [22])
        #expect(layout.placements[0].destinationRect == CGRect(x: 0, y: 0, width: 1920, height: 1080))
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
}
#endif
