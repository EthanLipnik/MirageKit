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
        #expect(first.tileCount == 4)
        #expect(first.dirtyTileCount == 4)
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
        #expect(idle.classification.summary.reusedTileVersions.count == 4)

        let dirtyResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: false,
            frameNumber: 3
        ))
        let dirty = try #require(dirtyResult)
        #expect(dirty.dirtyTileCount == 4)
        #expect(dirty.classification.decisions.allSatisfy {
            $0.reasons == [.captureMarkedDirty]
        })
    }

    @Test("Pixel signatures suppress unchanged non-idle tiles")
    func pixelSignaturesSuppressUnchangedNonIdleTiles() throws {
        var tracker = StreamContextMosaicDirtyTileTracker()
        let logicalSize = MiragePixelSize(width: 3000, height: 1800)
        let stableSignatures: (MirageMosaicTilePlan) -> [MirageMosaicTileID: MirageMosaicTileSignature] = { plan in
            Dictionary(uniqueKeysWithValues: plan.tiles.enumerated().map { index, tile in
                (tile.id, MirageMosaicTileSignature(lumaHash: UInt64(index + 1), sampleCount: 16))
            })
        }

        let firstResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: logicalSize,
            codec: .hevc,
            isIdleFrame: false,
            frameNumber: 1
        ), signaturesFor: stableSignatures)
        let first = try #require(firstResult)
        #expect(first.dirtyTileCount == first.tileCount)
        let changedTileID = try #require(first.plan.tiles.dropFirst().first?.id)

        let unchangedResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: logicalSize,
            codec: .hevc,
            isIdleFrame: false,
            frameNumber: 2
        ), signaturesFor: stableSignatures)
        let unchanged = try #require(unchangedResult)
        #expect(unchanged.dirtyTileCount == 0)

        let changedResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: logicalSize,
            codec: .hevc,
            isIdleFrame: false,
            frameNumber: 3
        ), signaturesFor: { plan in
            var signatures = stableSignatures(plan)
            signatures[changedTileID] = MirageMosaicTileSignature(lumaHash: 0xFF, sampleCount: 16)
            return signatures
        })
        let changed = try #require(changedResult)
        #expect(changed.dirtyTileCount == 1)
        #expect(changed.classification.summary.dirtyTileIDs == [changedTileID])
        #expect(changed.classification.decisions.first { $0.tileID == changedTileID }?.reasons == [.signatureChanged])
    }

    @Test("Forced refresh provider marks one unchanged tile dirty")
    func forcedRefreshProviderMarksOneUnchangedTileDirty() throws {
        var tracker = StreamContextMosaicDirtyTileTracker()
        let logicalSize = MiragePixelSize(width: 3000, height: 1800)
        let signatures: (MirageMosaicTilePlan) -> [MirageMosaicTileID: MirageMosaicTileSignature] = { plan in
            Dictionary(uniqueKeysWithValues: plan.tiles.enumerated().map { index, tile in
                (tile.id, MirageMosaicTileSignature(lumaHash: UInt64(index + 1), sampleCount: 16))
            })
        }

        let firstResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: logicalSize,
            codec: .hevc,
            isIdleFrame: false,
            frameNumber: 1
        ), signaturesFor: signatures)
        let first = try #require(firstResult)
        let forcedTileID = try #require(first.plan.tiles.dropFirst(2).first?.id)

        let refreshResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: logicalSize,
            codec: .hevc,
            isIdleFrame: false,
            frameNumber: 2
        ), signaturesFor: signatures, forcedRefreshTileIDsFor: { _ in [forcedTileID] })
        let refresh = try #require(refreshResult)

        #expect(refresh.dirtyTileCount == 1)
        #expect(refresh.classification.summary.dirtyTileIDs == [forcedTileID])
        #expect(refresh.classification.decisions.first { $0.tileID == forcedTileID }?.reasons == [.forcedRefresh])
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
                    id: MirageMosaicTileID(rawValue: "editor-scroll"),
                    rect: MiragePixelRect(x: 300, y: 200, width: 1800, height: 1200),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ]
        ))
        let semantic = try #require(semanticResult)

        #expect(semantic.plan.kind == .semantic)
        #expect(semantic.plan.epoch == fallback.plan.epoch + 1)
        #expect(semantic.plan.tiles.contains { $0.id == MirageMosaicTileID(rawValue: "editor-scroll") })
        #expect(semantic.dirtyTileCount == semantic.tileCount)
        #expect(semantic.classification.decisions.allSatisfy {
            $0.reasons.contains(.planEpochChanged)
        })
    }

    @Test("Tracker ignores semantic candidate ID churn when topology is unchanged")
    func trackerIgnoresSemanticCandidateIDChurnWhenTopologyIsUnchanged() throws {
        var tracker = StreamContextMosaicDirtyTileTracker()
        let firstResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 1,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "window-1-scroll-0"),
                    rect: MiragePixelRect(x: 300, y: 200, width: 1800, height: 1200),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ]
        ))
        let first = try #require(firstResult)

        let churnedResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 2,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "window-1-scroll-9"),
                    rect: MiragePixelRect(x: 300, y: 200, width: 1800, height: 1200),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ]
        ))
        let churned = try #require(churnedResult)

        #expect(churned.plan.id == first.plan.id)
        #expect(churned.plan.epoch == first.plan.epoch)
        #expect(churned.dirtyTileCount == 0)
    }

    @Test("Tracker ignores scroll and text viewport role churn for the same pane")
    func trackerIgnoresScrollAndTextViewportRoleChurnForSamePane() throws {
        var tracker = StreamContextMosaicDirtyTileTracker()
        let firstResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 1,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "editor-text"),
                    rect: MiragePixelRect(x: 300, y: 200, width: 1800, height: 1200),
                    semanticClass: .textViewport,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ]
        ))
        let first = try #require(firstResult)

        let roleChangedResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 2,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "editor-scroll"),
                    rect: MiragePixelRect(x: 300, y: 200, width: 1800, height: 1200),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ]
        ))
        let roleChanged = try #require(roleChangedResult)

        #expect(roleChanged.plan.id == first.plan.id)
        #expect(roleChanged.plan.epoch == first.plan.epoch)
        #expect(roleChanged.dirtyTileCount == 0)
    }

    @Test("Tracker freezes current plan while system state is transient")
    func trackerFreezesCurrentPlanWhileSystemStateIsTransient() throws {
        var tracker = StreamContextMosaicDirtyTileTracker(
            semanticPlanChangeStableFrameInterval: 1,
            transientSemanticPlanChangeStableFrameInterval: 1
        )
        let firstResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 1,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "editor-scroll"),
                    rect: MiragePixelRect(x: 300, y: 200, width: 1800, height: 1200),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ]
        ))
        let first = try #require(firstResult)

        let transientResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 20,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "small-transient-field"),
                    rect: MiragePixelRect(x: 620, y: 1320, width: 280, height: 44),
                    semanticClass: .textViewport,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "stage-manager-pane"),
                    rect: MiragePixelRect(x: 80, y: 300, width: 420, height: 900),
                    semanticClass: .scrollView,
                    priority: .semanticContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ],
            isTransientSystemState: true
        ))
        let transient = try #require(transientResult)

        #expect(transient.plan.id == first.plan.id)
        #expect(transient.plan.epoch == first.plan.epoch)
        #expect(!transient.plan.tiles.contains {
            $0.id == MirageMosaicTileID(rawValue: "small-transient-field")
        })
        #expect(!transient.plan.tiles.contains {
            $0.id == MirageMosaicTileID(rawValue: "stage-manager-pane")
        })
    }

    @Test("Tracker defers semantic topology changes until stable")
    func trackerDefersSemanticTopologyChangesUntilStable() throws {
        var tracker = StreamContextMosaicDirtyTileTracker(
            semanticPlanChangeStableFrameInterval: 3,
            transientSemanticPlanChangeStableFrameInterval: 3
        )
        let firstResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 1,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "editor-scroll"),
                    rect: MiragePixelRect(x: 300, y: 200, width: 1800, height: 1200),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ]
        ))
        let first = try #require(firstResult)

        let pendingResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 2,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "editor-scroll"),
                    rect: MiragePixelRect(x: 360, y: 220, width: 1700, height: 1100),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ]
        ))
        let pending = try #require(pendingResult)
        #expect(pending.plan.id == first.plan.id)
        #expect(pending.plan.epoch == first.plan.epoch)

        let stableResult = tracker.record(StreamContextMosaicDirtyTileFrame(
            logicalSize: MiragePixelSize(width: 3000, height: 1800),
            codec: .hevc,
            isIdleFrame: true,
            frameNumber: 5,
            semanticCandidates: [
                StreamContextMosaicSemanticCandidate(
                    id: MirageMosaicTileID(rawValue: "editor-scroll"),
                    rect: MiragePixelRect(x: 360, y: 220, width: 1700, height: 1100),
                    semanticClass: .scrollView,
                    priority: .focusedContent,
                    commitPolicy: .atomic,
                    isReliable: true
                ),
            ]
        ))
        let stable = try #require(stableResult)

        #expect(stable.plan.epoch == first.plan.epoch + 1)
        #expect(stable.plan.tiles.contains {
            $0.sourceRect == MiragePixelRect(x: 360, y: 220, width: 1700, height: 1100)
        })
    }
}
#endif
