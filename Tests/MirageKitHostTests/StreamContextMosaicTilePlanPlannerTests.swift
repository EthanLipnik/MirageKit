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
        #expect(semanticPlan.tiles.contains { $0.semanticClass == .gridFallback })
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
        #expect(plan.tiles.contains { $0.semanticClass == .gridFallback })
        #expect(plan.codecUnits.count == plan.tiles.count)
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
        #expect(plan.tiles.filter { $0.semanticClass != .gridFallback }.count == 12)
        #expect(plan.tiles.contains { $0.semanticClass == .gridFallback })
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
