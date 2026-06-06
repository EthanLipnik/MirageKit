//
//  StreamContextMosaicDirtyTileTrackerTests.swift
//  MirageKitHost
//
//  Created by Ethan Lipnik on 6/6/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageMedia
import Testing

@Suite("StreamContext Mosaic Dirty Tile Tracker")
struct StreamContextMosaicDirtyTileTrackerTests {
    @Test("Capture metadata fallback marks first and non-idle planned tiles dirty")
    func captureMetadataFallbackMarksFirstAndNonIdlePlannedTilesDirty() throws {
        var tracker = StreamContextMosaicDirtyTileTracker()

        let firstResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 1
        ))
        let first = try #require(firstResult)
        #expect(first.plan.kind == .fixedGrid)
        #expect(first.tileCount == 9)
        #expect(first.dirtyTileCount == 9)
        #expect(first.classification.decisions.allSatisfy {
            $0.reasons.contains(.firstObservation) && $0.reasons.contains(.planEpochChanged)
        })

        let idleResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 2
        ))
        let idle = try #require(idleResult)
        #expect(idle.dirtyTileCount == 0)
        #expect(idle.classification.summary.reusedTileVersions.count == 9)

        let dirtyResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: false,
            frameNumber: 3
        ))
        let dirty = try #require(dirtyResult)
        #expect(dirty.dirtyTileCount == 9)
        #expect(dirty.classification.decisions.allSatisfy {
            $0.reasons == [.captureMarkedDirty]
        })
    }

    @Test("Tracker publishes a new plan epoch when logical size changes")
    func trackerPublishesNewPlanEpochWhenLogicalSizeChanges() throws {
        var tracker = StreamContextMosaicDirtyTileTracker()
        let firstResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 1
        ))
        let first = try #require(firstResult)

        let resizedResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3200, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 2
        ))
        let resized = try #require(resizedResult)

        #expect(resized.plan.id != first.plan.id)
        #expect(resized.plan.epoch == first.plan.epoch + 1)
        #expect(resized.dirtyTileCount == resized.tileCount)
        #expect(resized.classification.decisions.allSatisfy {
            $0.reasons.contains(.planEpochChanged)
        })
    }

    @Test("Tracker publishes a semantic epoch when candidates arrive after fallback")
    func trackerPublishesSemanticEpochWhenCandidatesArriveAfterFallback() throws {
        var tracker = StreamContextMosaicDirtyTileTracker()
        let fallbackResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 1
        ))
        let fallback = try #require(fallbackResult)
        #expect(fallback.plan.kind == .fixedGrid)

        let semanticResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 2,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "focused-window"),
                    rect: MiragePixelRect(x: 300, y: 200, width: 1800, height: 1200),
                    semanticClass: .focusedWindow,
                    priority: .focusedContent,
                    isReliable: true
                ),
            ]
        ))
        let semantic = try #require(semanticResult)

        #expect(semantic.plan.kind == .semantic)
        #expect(semantic.plan.epoch == fallback.plan.epoch + 1)
        #expect(semantic.plan.tiles.contains { $0.id == MirageMosaicTileID(rawValue: "focused-window") })
        #expect(semantic.dirtyTileCount == semantic.tileCount)
        #expect(semantic.classification.decisions.allSatisfy {
            $0.reasons.contains(.planEpochChanged)
        })
    }
}
#endif
