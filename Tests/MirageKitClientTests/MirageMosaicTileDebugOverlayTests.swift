//
//  MirageMosaicTileDebugOverlayTests.swift
//  MirageKitClient
//
//  Created by Ethan Lipnik on 6/6/26.
//

import CoreGraphics
import MirageMedia
@testable import MirageKitClient
import Testing

@Suite("Mirage Mosaic Tile Debug Overlay")
struct MirageMosaicTileDebugOverlayTests {
    @Test("Overlay model scales announced semantic tile plan into aspect-fit content rect")
    func overlayModelScalesAnnouncedSemanticTilePlanIntoAspectFitContentRect() {
        let tile = MirageMosaicTileDescriptor(
            id: MirageMosaicTileID(rawValue: "scroll"),
            sourceRect: MiragePixelRect(x: 100, y: 50, width: 400, height: 300),
            presentationRect: MiragePixelRect(x: 100, y: 50, width: 400, height: 300),
            semanticClass: .scrollView,
            priority: .focusedContent
        )
        let unit = MirageMosaicCodecUnitDescriptor(
            id: MirageMosaicCodecUnitID(rawValue: "scroll"),
            tileID: tile.id,
            sourceRect: tile.sourceRect,
            presentationRect: tile.presentationRect,
            encodedSize: tile.sourceRect.size,
            codec: .hevc,
            transportGroupID: tile.transportGroupID,
            presentationGroupID: tile.presentationGroupID,
            commitPolicy: tile.commitPolicy
        )
        let plan = MirageMosaicTilePlan(
            epoch: 7,
            kind: .semantic,
            logicalSize: MiragePixelSize(width: 1000, height: 500),
            tiles: [tile],
            codecUnits: [unit]
        )

        let model = MirageMosaicTileDebugOverlayModel.model(
            tilePlan: plan,
            containerSize: CGSize(width: 1000, height: 1000)
        )

        #expect(model.contentRect == CGRect(x: 0, y: 250, width: 1000, height: 500))
        #expect(model.epochLabel == "Mosaic e7")
        #expect(model.tiles.count == 1)
        #expect(model.tiles[0].id == "scroll")
        #expect(model.tiles[0].label == "scroll scrollView")
        #expect(model.tiles[0].sourceRect == MiragePixelRect(x: 100, y: 50, width: 400, height: 300))
        #expect(model.tiles[0].semanticClass == .scrollView)
        #expect(model.tiles[0].rect == CGRect(x: 100, y: 300, width: 400, height: 300))
    }

    @Test("Overlay model falls back to visible 3x3 grid")
    func overlayModelFallsBackToVisibleGrid() {
        let model = MirageMosaicTileDebugOverlayModel.model(
            tilePlan: nil,
            containerSize: CGSize(width: 900, height: 600)
        )

        #expect(model.tiles.count == 9)
        #expect(model.epochLabel == "Mosaic e0")
        #expect(model.tiles[0].rect == CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(model.tiles[8].rect == CGRect(x: 600, y: 400, width: 300, height: 200))
        #expect(model.tiles.allSatisfy { $0.semanticClass == .gridFallback })
    }
}
