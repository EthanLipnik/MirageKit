//
//  StreamContextMosaicDirtyTileTracker.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/6/26.
//

import CoreGraphics
import Foundation
import MirageMedia

#if os(macOS)

struct StreamContextMosaicDirtyTileFrame: Sendable, Equatable {
    let logicalSize: MiragePixelSize
    let codec: MirageVideoCodec
    let isIdleFrame: Bool
    let frameNumber: UInt32
    let signaturesByTileID: [MirageMosaicTileID: MirageMosaicTileSignature]
    let keyframeRequiredTileIDs: Set<MirageMosaicTileID>
    let forcedRefreshTileIDs: Set<MirageMosaicTileID>
    let semanticCandidates: [StreamContextMosaicSemanticCandidate]
    let isTransientSystemState: Bool

    init(
        logicalSize: MiragePixelSize,
        codec: MirageVideoCodec,
        isIdleFrame: Bool,
        frameNumber: UInt32,
        signaturesByTileID: [MirageMosaicTileID: MirageMosaicTileSignature] = [:],
        keyframeRequiredTileIDs: Set<MirageMosaicTileID> = [],
        forcedRefreshTileIDs: Set<MirageMosaicTileID> = [],
        semanticCandidates: [StreamContextMosaicSemanticCandidate] = [],
        isTransientSystemState: Bool = false
    ) {
        self.logicalSize = logicalSize
        self.codec = codec
        self.isIdleFrame = isIdleFrame
        self.frameNumber = frameNumber
        self.signaturesByTileID = signaturesByTileID
        self.keyframeRequiredTileIDs = keyframeRequiredTileIDs
        self.forcedRefreshTileIDs = forcedRefreshTileIDs
        self.semanticCandidates = semanticCandidates
        self.isTransientSystemState = isTransientSystemState
    }
}

struct StreamContextMosaicDirtyTileTrackingResult: Sendable, Equatable {
    let plan: MirageMosaicTilePlan
    let classification: MirageMosaicDirtyTileClassifierResult

    var dirtyTileCount: Int {
        classification.summary.dirtyTileIDs.count
    }

    var tileCount: Int {
        plan.tiles.count
    }
}

/// Host-side bridge from capture metadata to planned Mosaic tile dirty state.
struct StreamContextMosaicDirtyTileTracker: Sendable {
    private let planner: StreamContextMosaicTilePlanPlanner
    private var classifier: MirageMosaicDirtyTileClassifier
    private var currentPlan: MirageMosaicTilePlan?
    private var currentPlanSemanticCandidates: [StreamContextMosaicSemanticCandidate] = []

    init(
        planner: StreamContextMosaicTilePlanPlanner = StreamContextMosaicTilePlanPlanner(),
        staleRefreshFrameInterval: UInt32 = 0
    ) {
        self.planner = planner
        classifier = MirageMosaicDirtyTileClassifier(staleRefreshFrameInterval: staleRefreshFrameInterval)
    }

    mutating func reset() {
        currentPlan = nil
        currentPlanSemanticCandidates = []
        classifier.reset()
    }

    mutating func record(_ frame: StreamContextMosaicDirtyTileFrame) -> StreamContextMosaicDirtyTileTrackingResult? {
        guard !frame.logicalSize.isEmpty else { return nil }
        let plan = resolvedPlan(
            logicalSize: frame.logicalSize,
            codec: frame.codec,
            semanticCandidates: frame.semanticCandidates,
            isTransientSystemState: frame.isTransientSystemState
        )
        let captureMarkedDirtyTileIDs = frame.isIdleFrame ? Set<MirageMosaicTileID>() : Set(plan.tiles.map(\.id))
        let classification = classifier.classify(
            plan: plan,
            frameNumber: frame.frameNumber,
            signaturesByTileID: frame.signaturesByTileID,
            captureMarkedDirtyTileIDs: captureMarkedDirtyTileIDs,
            keyframeRequiredTileIDs: frame.keyframeRequiredTileIDs,
            forcedRefreshTileIDs: frame.forcedRefreshTileIDs
        )
        return StreamContextMosaicDirtyTileTrackingResult(plan: plan, classification: classification)
    }

    private mutating func resolvedPlan(
        logicalSize: MiragePixelSize,
        codec: MirageVideoCodec,
        semanticCandidates: [StreamContextMosaicSemanticCandidate],
        isTransientSystemState: Bool
    ) -> MirageMosaicTilePlan {
        if let currentPlan,
           currentPlan.logicalSize == logicalSize,
           currentPlan.codecUnits.allSatisfy({ $0.codec == codec }),
           (isTransientSystemState || currentPlanSemanticCandidates == semanticCandidates) {
            return currentPlan
        }
        let nextEpoch = (currentPlan?.epoch ?? 0) &+ 1
        let plan = planner.plan(for: StreamContextMosaicTilePlanRequest(
            logicalSize: logicalSize,
            codec: codec,
            semanticCandidates: semanticCandidates,
            isTransientSystemState: isTransientSystemState,
            previousPlan: currentPlan
        ))
        if let currentPlan, plan == currentPlan {
            return currentPlan
        }
        let epochPlan = MirageMosaicTilePlan(
            id: plan.id,
            epoch: nextEpoch,
            kind: plan.kind,
            logicalSize: plan.logicalSize,
            tiles: plan.tiles,
            codecUnits: plan.codecUnits
        )
        currentPlan = epochPlan
        currentPlanSemanticCandidates = semanticCandidates
        return epochPlan
    }
}

extension MiragePixelSize {
    init(rounded size: CGSize) {
        self.init(
            width: Int(max(0, size.width).rounded()),
            height: Int(max(0, size.height).rounded())
        )
    }
}

#endif
