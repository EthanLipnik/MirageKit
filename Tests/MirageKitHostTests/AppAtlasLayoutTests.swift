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
