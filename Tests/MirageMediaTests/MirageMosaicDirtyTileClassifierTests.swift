//
//  MirageMosaicDirtyTileClassifierTests.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/6/26.
//

import MirageMedia
import Testing

@Suite("Mirage Mosaic Dirty Tile Classifier")
struct MirageMosaicDirtyTileClassifierTests {
    @Test("Classifier marks first observation dirty and then reuses stable signatures")
    func classifierMarksFirstObservationDirtyAndThenReusesStableSignatures() {
        let plan = MirageMosaicTilePlan.fixedGrid(
            logicalSize: MiragePixelSize(width: 900, height: 600),
            columns: 3,
            rows: 3,
            codec: .hevc
        )
        let signatures = Dictionary(uniqueKeysWithValues: plan.tiles.enumerated().map { index, tile in
            (tile.id, MirageMosaicTileSignature(lumaHash: UInt64(index + 1), sampleCount: 16))
        })
        var classifier = MirageMosaicDirtyTileClassifier()

        let first = classifier.classify(
            plan: plan,
            frameNumber: 1,
            signaturesByTileID: signatures
        )
        #expect(first.summary.dirtyTileIDs == plan.tiles.map(\.id).sorted())
        #expect(first.summary.updatedTileVersions.values.allSatisfy { $0 == 1 })
        #expect(first.decisions.allSatisfy { $0.reasons.contains(.firstObservation) })

        let second = classifier.classify(
            plan: plan,
            frameNumber: 2,
            signaturesByTileID: signatures
        )
        #expect(second.summary.dirtyTileIDs.isEmpty)
        #expect(second.summary.reusedTileVersions.count == plan.tiles.count)
        #expect(second.summary.reusedTileVersions.values.allSatisfy { $0 == 1 })
    }

    @Test("Classifier bumps only changed and forced tile versions")
    func classifierBumpsOnlyChangedAndForcedTileVersions() throws {
        let plan = MirageMosaicTilePlan.fixedGrid(
            logicalSize: MiragePixelSize(width: 900, height: 600),
            columns: 3,
            rows: 3,
            codec: .hevc
        )
        let changedTileID = plan.tiles[4].id
        let forcedTileID = plan.tiles[8].id
        var signatures = Dictionary(uniqueKeysWithValues: plan.tiles.enumerated().map { index, tile in
            (tile.id, MirageMosaicTileSignature(lumaHash: UInt64(index + 1), sampleCount: 16))
        })
        var classifier = MirageMosaicDirtyTileClassifier()
        _ = classifier.classify(plan: plan, frameNumber: 1, signaturesByTileID: signatures)

        signatures[changedTileID] = MirageMosaicTileSignature(lumaHash: 0xFF, sampleCount: 16)
        let result = classifier.classify(
            plan: plan,
            frameNumber: 2,
            signaturesByTileID: signatures,
            forcedRefreshTileIDs: [forcedTileID]
        )

        #expect(result.summary.dirtyTileIDs == [changedTileID, forcedTileID].sorted())
        #expect(result.summary.updatedTileVersions[changedTileID] == 2)
        #expect(result.summary.updatedTileVersions[forcedTileID] == 2)
        #expect(result.summary.reusedTileVersions.count == plan.tiles.count - 2)
        let changedDecision = try #require(result.decisions.first { $0.tileID == changedTileID })
        #expect(changedDecision.reasons.contains(.signatureChanged))
        let forcedDecision = try #require(result.decisions.first { $0.tileID == forcedTileID })
        #expect(forcedDecision.reasons.contains(.forcedRefresh))
    }
}
