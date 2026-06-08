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

    @Test("Dependency tracker uses last transport-sent version")
    func dependencyTrackerUsesLastTransportSentVersion() throws {
        let plan = MirageMosaicTilePlan.fixedGrid(
            epoch: 9,
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            columns: 3,
            rows: 3,
            codec: .hevc
        )
        let tileID = MirageMosaicTileID(rawValue: "grid-0")
        let planner = StreamContextMosaicMediaUnitPlanner()
        var tracker = StreamContextMosaicEncodedDependencyTracker()

        let keyframeUnit = try #require(Self.plannedUnit(
            planner: planner,
            plan: plan,
            tileID: tileID,
            tileVersion: 56
        ))
        let keyframeCandidate = tracker.workItemForEncoding(keyframeUnit, forceKeyframe: false)
        let keyframe = try #require(keyframeCandidate)
        #expect(keyframe.shouldForceKeyframe)
        #expect(keyframe.workItem.dependencyVersion == nil)
        tracker.noteTransportCompleted(keyframe.workItem.senderMetadata(unitFrameNumber: 56), didSend: true)

        let jumpedUnit = try #require(Self.plannedUnit(
            planner: planner,
            plan: plan,
            tileID: tileID,
            tileVersion: 71
        ))
        #expect(jumpedUnit.dependencyVersion == 70)

        let pFrameCandidate = tracker.workItemForEncoding(jumpedUnit, forceKeyframe: false)
        let pFrame = try #require(pFrameCandidate)
        #expect(!pFrame.shouldForceKeyframe)
        #expect(pFrame.workItem.tileVersion == 71)
        #expect(pFrame.workItem.dependencyVersion == 56)
        if tracker.workItemForEncoding(jumpedUnit, forceKeyframe: false) != nil {
            Issue.record("Expected in-flight Mosaic unit to block duplicate encoding.")
        }
        tracker.noteTransportCompleted(pFrame.workItem.senderMetadata(unitFrameNumber: 71), didSend: true)

        let nextUnit = try #require(Self.plannedUnit(
            planner: planner,
            plan: plan,
            tileID: tileID,
            tileVersion: 72
        ))
        let nextPFrameCandidate = tracker.workItemForEncoding(nextUnit, forceKeyframe: false)
        let nextPFrame = try #require(nextPFrameCandidate)
        #expect(!nextPFrame.shouldForceKeyframe)
        #expect(nextPFrame.workItem.dependencyVersion == 71)
    }

    @Test("Dependency tracker forces keyframe after transport drop")
    func dependencyTrackerForcesKeyframeAfterTransportDrop() throws {
        let plan = MirageMosaicTilePlan.fixedGrid(
            epoch: 9,
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            columns: 3,
            rows: 3,
            codec: .hevc
        )
        let tileID = MirageMosaicTileID(rawValue: "grid-0")
        let planner = StreamContextMosaicMediaUnitPlanner()
        var tracker = StreamContextMosaicEncodedDependencyTracker()

        let keyframeUnit = try #require(Self.plannedUnit(
            planner: planner,
            plan: plan,
            tileID: tileID,
            tileVersion: 10
        ))
        let keyframeCandidate = tracker.workItemForEncoding(keyframeUnit, forceKeyframe: false)
        let keyframe = try #require(keyframeCandidate)
        tracker.noteTransportCompleted(keyframe.workItem.senderMetadata(unitFrameNumber: 10), didSend: true)

        let pFrameUnit = try #require(Self.plannedUnit(
            planner: planner,
            plan: plan,
            tileID: tileID,
            tileVersion: 11
        ))
        let pFrameCandidate = tracker.workItemForEncoding(pFrameUnit, forceKeyframe: false)
        let pFrame = try #require(pFrameCandidate)
        #expect(!pFrame.shouldForceKeyframe)
        tracker.noteTransportCompleted(pFrame.workItem.senderMetadata(unitFrameNumber: 11), didSend: false)

        let recoveryUnit = try #require(Self.plannedUnit(
            planner: planner,
            plan: plan,
            tileID: tileID,
            tileVersion: 12
        ))
        let recoveryCandidate = tracker.workItemForEncoding(recoveryUnit, forceKeyframe: false)
        let recovery = try #require(recoveryCandidate)
        #expect(recovery.shouldForceKeyframe)
        #expect(recovery.workItem.dependencyVersion == nil)
    }

    @Test("Dependency tracker preserves sent dependency after local abandon")
    func dependencyTrackerPreservesSentDependencyAfterLocalAbandon() throws {
        let plan = MirageMosaicTilePlan.fixedGrid(
            epoch: 9,
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            columns: 3,
            rows: 3,
            codec: .hevc
        )
        let tileID = MirageMosaicTileID(rawValue: "grid-0")
        let planner = StreamContextMosaicMediaUnitPlanner()
        var tracker = StreamContextMosaicEncodedDependencyTracker()

        let keyframeUnit = try #require(Self.plannedUnit(
            planner: planner,
            plan: plan,
            tileID: tileID,
            tileVersion: 20
        ))
        let keyframeCandidate = tracker.workItemForEncoding(keyframeUnit, forceKeyframe: false)
        let keyframe = try #require(keyframeCandidate)
        tracker.noteTransportCompleted(keyframe.workItem.senderMetadata(unitFrameNumber: 20), didSend: true)

        let pFrameUnit = try #require(Self.plannedUnit(
            planner: planner,
            plan: plan,
            tileID: tileID,
            tileVersion: 21
        ))
        let pFrameCandidate = tracker.workItemForEncoding(pFrameUnit, forceKeyframe: false)
        let pFrame = try #require(pFrameCandidate)
        #expect(!pFrame.shouldForceKeyframe)
        #expect(pFrame.workItem.dependencyVersion == 20)

        tracker.noteEncodingAbandoned(pFrame.workItem)

        let retryCandidate = tracker.workItemForEncoding(pFrameUnit, forceKeyframe: false)
        let retry = try #require(retryCandidate)
        #expect(!retry.shouldForceKeyframe)
        #expect(retry.workItem.dependencyVersion == 20)
    }

    private static func plannedUnit(
        planner: StreamContextMosaicMediaUnitPlanner,
        plan: MirageMosaicTilePlan,
        tileID: MirageMosaicTileID,
        tileVersion: UInt32
    ) -> StreamContextMosaicMediaUnitWorkItem? {
        let summary = MirageMosaicEpochSummary(
            tilePlanID: plan.id,
            tilePlanEpoch: plan.epoch,
            frameNumber: tileVersion,
            dirtyTileIDs: [tileID],
            reusedTileVersions: [:],
            updatedTileVersions: [tileID: tileVersion]
        )
        return planner.plannedUnits(plan: plan, summary: summary).only
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
#endif
