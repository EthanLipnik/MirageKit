//
//  StreamContextMosaicTilePlanPlannerTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 6/6/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageMedia
import Testing

@Suite("StreamContext Mosaic Tile Plan Planner")
struct StreamContextMosaicTilePlanPlannerTests {
    @Test("Planner builds fixed-grid fallback when semantic metadata is unavailable")
    func plannerBuildsFixedGridFallbackWhenSemanticMetadataIsUnavailable() {
        let planner = StreamContextMosaicTilePlanPlanner()
        let logicalSize = MiragePixelSize(width: 3000, height: 1800)
        let plan = planner.plan(for: StreamContextMosaicTilePlanRequest(
            logicalSize: logicalSize,
            codec: .hevc
        ))

        #expect(plan.kind == .fixedGrid)
        #expect(plan.tiles.count == 4)
        #expect(plan.codecUnits.count == plan.tiles.count)
        #expect(plan.mediaTopology.kind == .mosaic)
        #expect(plan.tiles.allSatisfy { $0.sourceRect.width <= 1536 && $0.sourceRect.height <= 1024 })
        #expect(totalArea(plan.tiles.map(\.sourceRect)) == logicalSize.width * logicalSize.height)
        #expect(rectsDoNotOverlap(plan.tiles.map(\.sourceRect)))
    }

    @Test("Planner uses reliable semantic candidates and preserves previous plan when transient metadata disappears")
    func plannerUsesReliableSemanticCandidatesAndPreservesPreviousPlanWhenTransientMetadataDisappears() throws {
        let planner = StreamContextMosaicTilePlanPlanner()
        let scrollID = MirageMosaicTileID(rawValue: "scroll")
        let semanticPlan = planner.plan(for: StreamContextMosaicTilePlanRequest(
            logicalSize: MiragePixelSize(width: 4000, height: 2400),
            codec: .hevc,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: scrollID,
                    rect: MiragePixelRect(x: 100, y: 120, width: 2200, height: 1500),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    codecStrategy: .verticalColumns,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "stale"),
                    rect: MiragePixelRect(x: 0, y: 0, width: 100, height: 100),
                    semanticClass: .menu,
                    priority: .transientChrome,
                    isReliable: false
                ),
            ]
        ))

        #expect(semanticPlan.kind == .semantic)
        let scrollTiles = semanticPlan.tiles.filter {
            $0.id == scrollID || $0.parentTileID == scrollID
        }
        #expect(scrollTiles.count == 1)
        #expect(semanticPlan.tiles.contains { $0.semanticClass == .background })
        #expect(scrollTiles.allSatisfy { $0.semanticClass == .scrollView })
        #expect(scrollTiles.allSatisfy { $0.commitPolicy == .atomic })
        #expect(semanticPlan.codecUnits.count == semanticPlan.tiles.count)
        #expect(totalArea(semanticPlan.tiles.map(\.sourceRect)) == 4000 * 2400)
        #expect(rectsDoNotOverlap(semanticPlan.tiles.map(\.sourceRect)))

        let frozenPlan = planner.plan(for: StreamContextMosaicTilePlanRequest(
            logicalSize: MiragePixelSize(width: 4000, height: 2400),
            codec: .hevc,
            semanticCandidates: [],
            isTransientSystemState: true,
            previousPlan: semanticPlan
        ))
        #expect(frozenPlan == semanticPlan)
    }

    @Test("Planner lets text and scroll regions carve bounded fallback fill")
    func plannerLetsTextAndScrollRegionsCarveBoundedFallbackFill() throws {
        let planner = StreamContextMosaicTilePlanPlanner()
        let scrollID = MirageMosaicTileID(rawValue: "sidebar-scroll")
        let textID = MirageMosaicTileID(rawValue: "editor-text")

        let plan = planner.plan(for: StreamContextMosaicTilePlanRequest(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: scrollID,
                    rect: MiragePixelRect(x: 200, y: 160, width: 600, height: 1400),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
                StreamContextMosaicSemanticCandidate(
                    id: textID,
                    rect: MiragePixelRect(x: 900, y: 260, width: 1300, height: 900),
                    semanticClass: .textViewport,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ]
        ))

        let scrollTile = try #require(plan.tiles.first { $0.id == scrollID })
        let textTile = try #require(plan.tiles.first { $0.id == textID })
        #expect(scrollTile.sourceRect == MiragePixelRect(x: 200, y: 160, width: 600, height: 1400))
        #expect(textTile.sourceRect == MiragePixelRect(x: 900, y: 260, width: 1300, height: 900))
        #expect(!plan.tiles.contains { $0.semanticClass == .focusedWindow })
        #expect(plan.tiles.contains { $0.semanticClass == .background })
        #expect(plan.codecUnits.count == plan.tiles.count)
        #expect(totalArea(plan.tiles.map(\.sourceRect)) == 3000 * 1800)
        #expect(rectsDoNotOverlap(plan.tiles.map(\.sourceRect)))
    }

    @Test("Planner keeps coarse Xcode panes and bounded desktop background")
    func plannerKeepsCoarseXcodePanesAndBoundedDesktopBackground() throws {
        let planner = StreamContextMosaicTilePlanPlanner()
        let nestedStripID = MirageMosaicTileID(rawValue: "editor-nested-strip")
        let plan = planner.plan(for: StreamContextMosaicTilePlanRequest(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "menu-bar"),
                    rect: MiragePixelRect(x: 0, y: 0, width: 3000, height: 44),
                    semanticClass: .menuBar,
                    priority: .transientChrome,
                    isReliable: true
                ),
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "dock"),
                    rect: MiragePixelRect(x: 0, y: 1680, width: 3000, height: 120),
                    semanticClass: .dock,
                    priority: .transientChrome,
                    isReliable: true
                ),
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "toolbar"),
                    rect: MiragePixelRect(x: 450, y: 120, width: 2100, height: 90),
                    semanticClass: .toolbar,
                    priority: .transientChrome,
                    isReliable: true
                ),
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "sidebar"),
                    rect: MiragePixelRect(x: 450, y: 210, width: 360, height: 1230),
                    semanticClass: .sidebar,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "editor"),
                    rect: MiragePixelRect(x: 810, y: 210, width: 1740, height: 900),
                    semanticClass: .textViewport,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "console"),
                    rect: MiragePixelRect(x: 810, y: 1110, width: 1740, height: 330),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
                StreamContextMosaicSemanticCandidate(
                    id: nestedStripID,
                    rect: MiragePixelRect(x: 860, y: 320, width: 240, height: 40),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ]
        ))

        #expect(plan.kind == .semantic)
        #expect(plan.tiles.contains { $0.semanticClass == .menuBar })
        #expect(plan.tiles.contains { $0.semanticClass == .dock })
        #expect(plan.tiles.contains { $0.semanticClass == .toolbar })
        #expect(plan.tiles.contains { $0.semanticClass == .sidebar })
        #expect(plan.tiles.contains { $0.id == MirageMosaicTileID(rawValue: "editor") })
        #expect(plan.tiles.contains { $0.id == MirageMosaicTileID(rawValue: "console") })
        #expect(!plan.tiles.contains { $0.id == nestedStripID })

        let semanticTileCount = plan.tiles.filter { $0.semanticClass != .background }.count
        let backgroundTileCount = plan.tiles.filter { $0.semanticClass == .background }.count
        #expect(semanticTileCount == 6)
        #expect(backgroundTileCount <= 8)
        #expect(totalArea(plan.tiles.map(\.sourceRect)) == 3000 * 1800)
        #expect(rectsDoNotOverlap(plan.tiles.map(\.sourceRect)))
    }

    @Test("Planner caps semantic islands and still fills residual screen area")
    func plannerCapsSemanticIslandsAndStillFillsResidualScreenArea() {
        let planner = StreamContextMosaicTilePlanPlanner(maxSemanticTiles: 12)
        var candidates: [StreamContextMosaicSemanticCandidate] = []
        for index in 0 ..< 20 {
            candidates.append(StreamContextMosaicSemanticCandidate(
                id: MirageMosaicTileID(rawValue: "pane-\(index)"),
                rect: MiragePixelRect(
                    x: 120 + (index % 5) * 540,
                    y: 120 + (index / 5) * 320,
                    width: 420,
                    height: 240
                ),
                semanticClass: index % 2 == 0 ? .scrollView : .textViewport,
                priority: .focusedContent,
                commitPolicy: .atomic,
                isReliable: true
            ))
        }

        let plan = planner.plan(for: StreamContextMosaicTilePlanRequest(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            semanticCandidates: candidates
        ))

        #expect(plan.kind == .semantic)
        #expect(plan.tiles.filter { $0.semanticClass != .background }.count == 12)
        #expect(plan.tiles.contains { $0.semanticClass == .background })
        #expect(totalArea(plan.tiles.map(\.sourceRect)) == 3000 * 1800)
        #expect(rectsDoNotOverlap(plan.tiles.map(\.sourceRect)))
    }
}

private func totalArea(_ rects: [MiragePixelRect]) -> Int {
    rects.reduce(0) { area, rect in
        area + rect.width * rect.height
    }
}

private func rectsDoNotOverlap(_ rects: [MiragePixelRect]) -> Bool {
    for lhsIndex in rects.indices {
        for rhsIndex in rects.indices where rhsIndex > lhsIndex {
            if intersects(rects[lhsIndex], rects[rhsIndex]) {
                return false
            }
        }
    }
    return true
}

private func intersects(_ lhs: MiragePixelRect, _ rhs: MiragePixelRect) -> Bool {
    max(lhs.x, rhs.x) < min(lhs.x + lhs.width, rhs.x + rhs.width) &&
        max(lhs.y, rhs.y) < min(lhs.y + lhs.height, rhs.y + rhs.height)
}
#endif
