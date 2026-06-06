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
        let planner = StreamContextMosaicTilePlanPlanner(fallbackColumns: 3, fallbackRows: 3)
        let plan = planner.plan(for: StreamContextMosaicTilePlanRequest(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc
        ))

        #expect(plan.kind == .fixedGrid)
        #expect(plan.tiles.count == 9)
        #expect(plan.codecUnits.count == 9)
        #expect(plan.mediaTopology.kind == .mosaic)
    }

    @Test("Planner uses reliable semantic candidates and freezes during transient states")
    func plannerUsesReliableSemanticCandidatesAndFreezesDuringTransientStates() throws {
        let planner = StreamContextMosaicTilePlanPlanner()
        let semanticPlan = planner.plan(for: StreamContextMosaicTilePlanRequest(
            logicalSize: MiragePixelSize(width: 4000, height: 2400),
            codec: .hevc,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "scroll"),
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
        #expect(semanticPlan.tiles.contains { $0.id == MirageMosaicTileID(rawValue: "scroll") })
        #expect(semanticPlan.tiles.contains { $0.semanticClass == .gridFallback })
        let scrollTile = try #require(semanticPlan.tiles.first { $0.id == MirageMosaicTileID(rawValue: "scroll") })
        #expect(scrollTile.semanticClass == .scrollView)
        #expect(scrollTile.commitPolicy == .atomic)
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
}

private func totalArea(_ rects: [MiragePixelRect]) -> Int {
    rects.reduce(0) { $0 + $1.width * $1.height }
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
