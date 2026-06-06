//
//  StreamContextMosaicMediaUnitPlannerTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 6/6/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageMedia
import Testing

@Suite("StreamContext Mosaic Media Unit Planner")
struct StreamContextMosaicMediaUnitPlannerTests {
    @Test("Planner selects dirty codec units with stable indices and versions")
    func plannerSelectsDirtyCodecUnitsWithStableIndicesAndVersions() throws {
        let plan = MirageMosaicTilePlan.fixedGrid(
            epoch: 9,
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            columns: 3,
            rows: 3,
            codec: .hevc
        )
        let dirtyTileID = MirageMosaicTileID(rawValue: "grid-4")
        let reusedTileID = MirageMosaicTileID(rawValue: "grid-0")
        let summary = MirageMosaicEpochSummary(
            tilePlanID: plan.id,
            tilePlanEpoch: plan.epoch,
            frameNumber: 44,
            dirtyTileIDs: [dirtyTileID],
            reusedTileVersions: [reusedTileID: 2],
            updatedTileVersions: [dirtyTileID: 5]
        )

        let units = StreamContextMosaicMediaUnitPlanner().plannedUnits(
            plan: plan,
            summary: summary
        )

        let unit = try #require(units.only)
        #expect(unit.tile.id == dirtyTileID)
        #expect(unit.codecUnit.tileID == dirtyTileID)
        #expect(unit.mediaUnitIndex == 4)
        #expect(unit.tileIndex == 4)
        #expect(unit.tileVersion == 5)
        #expect(unit.dependencyVersion == 4)
        #expect(unit.isDirty)

        let metadata = unit.senderMetadata(unitFrameNumber: summary.frameNumber)
        #expect(metadata.tilePlanEpoch == 9)
        #expect(metadata.mediaEpoch == 44)
        #expect(metadata.mediaUnitIndex == 4)
        #expect(metadata.tileIndex == 4)
        #expect(metadata.tileVersion == 5)
        #expect(metadata.dependencyVersion == 4)
    }

    @Test("Planner can include clean codec units for keyframe refresh")
    func plannerCanIncludeCleanCodecUnitsForKeyframeRefresh() {
        let plan = MirageMosaicTilePlan.fixedGrid(
            epoch: 3,
            logicalSize: MiragePixelSize(width: 1200, height: 800),
            columns: 3,
            rows: 1,
            codec: .hevc
        )
        let summary = MirageMosaicEpochSummary(
            tilePlanID: plan.id,
            tilePlanEpoch: plan.epoch,
            frameNumber: 8,
            dirtyTileIDs: [],
            reusedTileVersions: [
                MirageMosaicTileID(rawValue: "grid-0"): 1,
                MirageMosaicTileID(rawValue: "grid-1"): 2,
                MirageMosaicTileID(rawValue: "grid-2"): 3,
            ],
            updatedTileVersions: [:]
        )

        let units = StreamContextMosaicMediaUnitPlanner().plannedUnits(
            plan: plan,
            summary: summary,
            includeCleanUnits: true
        )

        #expect(units.count == 3)
        #expect(units.map(\.tileVersion) == [1, 2, 3])
        #expect(units.allSatisfy { !$0.isDirty })
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
#endif
