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
    private struct SemanticCandidateSignature: Sendable, Equatable, Comparable {
        let semanticClass: MirageMosaicSemanticClass
        let priority: MirageMosaicTilePriority
        let rect: QuantizedRect
        let codecStrategy: MirageMosaicCodecStrategy
        let commitPolicy: MirageMosaicCommitPolicy

        static func < (lhs: SemanticCandidateSignature, rhs: SemanticCandidateSignature) -> Bool {
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.semanticClass.rawValue != rhs.semanticClass.rawValue {
                return lhs.semanticClass.rawValue < rhs.semanticClass.rawValue
            }
            if lhs.rect != rhs.rect { return lhs.rect < rhs.rect }
            if lhs.codecStrategy.rawValue != rhs.codecStrategy.rawValue {
                return lhs.codecStrategy.rawValue < rhs.codecStrategy.rawValue
            }
            return lhs.commitPolicy.rawValue < rhs.commitPolicy.rawValue
        }
    }

    private struct QuantizedRect: Sendable, Equatable, Comparable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init(_ rect: MiragePixelRect, bucketSize: Int = 16) {
            x = Self.quantized(rect.x, bucketSize: bucketSize)
            y = Self.quantized(rect.y, bucketSize: bucketSize)
            width = Self.quantized(rect.width, bucketSize: bucketSize)
            height = Self.quantized(rect.height, bucketSize: bucketSize)
        }

        static func < (lhs: QuantizedRect, rhs: QuantizedRect) -> Bool {
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.height != rhs.height { return lhs.height < rhs.height }
            return lhs.width < rhs.width
        }

        private static func quantized(_ value: Int, bucketSize: Int) -> Int {
            guard bucketSize > 1 else { return value }
            return ((value + bucketSize / 2) / bucketSize) * bucketSize
        }
    }

    private struct PendingSemanticPlanChange: Sendable {
        let signature: [SemanticCandidateSignature]
        let firstObservedFrameNumber: UInt32
    }

    private let planner: StreamContextMosaicTilePlanPlanner
    private let semanticPlanChangeStableFrameInterval: UInt32
    private let transientSemanticPlanChangeStableFrameInterval: UInt32
    private var classifier: MirageMosaicDirtyTileClassifier
    private var currentPlan: MirageMosaicTilePlan?
    private var currentPlanSemanticSignature: [SemanticCandidateSignature] = []
    private var pendingSemanticPlanChange: PendingSemanticPlanChange?

    init(
        planner: StreamContextMosaicTilePlanPlanner = StreamContextMosaicTilePlanPlanner(),
        staleRefreshFrameInterval: UInt32 = 0,
        semanticPlanChangeStableFrameInterval: UInt32 = 30,
        transientSemanticPlanChangeStableFrameInterval: UInt32 = 45
    ) {
        self.planner = planner
        self.semanticPlanChangeStableFrameInterval = semanticPlanChangeStableFrameInterval
        self.transientSemanticPlanChangeStableFrameInterval = transientSemanticPlanChangeStableFrameInterval
        classifier = MirageMosaicDirtyTileClassifier(staleRefreshFrameInterval: staleRefreshFrameInterval)
    }

    mutating func reset() {
        currentPlan = nil
        currentPlanSemanticSignature = []
        pendingSemanticPlanChange = nil
        classifier.reset()
    }

    mutating func record(
        _ frame: StreamContextMosaicDirtyTileFrame,
        signaturesFor signatureProvider: ((MirageMosaicTilePlan) -> [MirageMosaicTileID: MirageMosaicTileSignature])? = nil,
        forcedRefreshTileIDsFor forcedRefreshProvider: ((MirageMosaicTilePlan) -> Set<MirageMosaicTileID>)? = nil
    ) -> StreamContextMosaicDirtyTileTrackingResult? {
        guard !frame.logicalSize.isEmpty else { return nil }
        let plan = resolvedPlan(
            logicalSize: frame.logicalSize,
            codec: frame.codec,
            semanticCandidates: frame.semanticCandidates,
            isTransientSystemState: frame.isTransientSystemState,
            frameNumber: frame.frameNumber
        )
        let signaturesByTileID = signatureProvider?(plan) ?? frame.signaturesByTileID
        let forcedRefreshTileIDs = frame.forcedRefreshTileIDs.union(forcedRefreshProvider?(plan) ?? [])
        let captureMarkedDirtyTileIDs = if frame.isIdleFrame || !signaturesByTileID.isEmpty {
            Set<MirageMosaicTileID>()
        } else {
            Set(plan.tiles.map(\.id))
        }
        let classification = classifier.classify(
            plan: plan,
            frameNumber: frame.frameNumber,
            signaturesByTileID: signaturesByTileID,
            captureMarkedDirtyTileIDs: captureMarkedDirtyTileIDs,
            keyframeRequiredTileIDs: frame.keyframeRequiredTileIDs,
            forcedRefreshTileIDs: forcedRefreshTileIDs
        )
        return StreamContextMosaicDirtyTileTrackingResult(plan: plan, classification: classification)
    }

    private mutating func resolvedPlan(
        logicalSize: MiragePixelSize,
        codec: MirageVideoCodec,
        semanticCandidates: [StreamContextMosaicSemanticCandidate],
        isTransientSystemState: Bool,
        frameNumber: UInt32
    ) -> MirageMosaicTilePlan {
        let semanticSignature = semanticSignature(for: semanticCandidates)
        if let currentPlan,
           currentPlan.logicalSize == logicalSize,
           currentPlan.codecUnits.allSatisfy({ $0.codec == codec }),
           currentPlanSemanticSignature == semanticSignature {
            pendingSemanticPlanChange = nil
            return currentPlan
        }
        if isTransientSystemState,
           semanticCandidates.isEmpty,
           let currentPlan,
           currentPlan.logicalSize == logicalSize,
           currentPlan.codecUnits.allSatisfy({ $0.codec == codec }) {
            return currentPlan
        }
        if shouldDeferSemanticPlanChange(
            semanticSignature,
            semanticCandidates: semanticCandidates,
            isTransientSystemState: isTransientSystemState,
            logicalSize: logicalSize,
            codec: codec,
            frameNumber: frameNumber
        ) {
            return currentPlan ?? fixedPlan(logicalSize: logicalSize, codec: codec)
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
        pendingSemanticPlanChange = nil
        let epochPlan = MirageMosaicTilePlan(
            id: plan.id,
            epoch: nextEpoch,
            kind: plan.kind,
            logicalSize: plan.logicalSize,
            tiles: plan.tiles,
            codecUnits: plan.codecUnits
        )
        currentPlan = epochPlan
        currentPlanSemanticSignature = semanticSignature
        return epochPlan
    }

    private mutating func shouldDeferSemanticPlanChange(
        _ semanticSignature: [SemanticCandidateSignature],
        semanticCandidates: [StreamContextMosaicSemanticCandidate],
        isTransientSystemState: Bool,
        logicalSize: MiragePixelSize,
        codec: MirageVideoCodec,
        frameNumber: UInt32
    ) -> Bool {
        guard let currentPlan,
              currentPlan.logicalSize == logicalSize,
              currentPlan.codecUnits.allSatisfy({ $0.codec == codec }) else {
            pendingSemanticPlanChange = nil
            return false
        }
        guard currentPlan.kind != .fixedGrid || semanticCandidates.isEmpty else {
            pendingSemanticPlanChange = nil
            return false
        }

        let stableFrameInterval = isTransientSystemState
            ? transientSemanticPlanChangeStableFrameInterval
            : semanticPlanChangeStableFrameInterval
        guard stableFrameInterval > 0 else { return false }

        if let pendingSemanticPlanChange,
           pendingSemanticPlanChange.signature == semanticSignature {
            return frameNumber &- pendingSemanticPlanChange.firstObservedFrameNumber < stableFrameInterval
        }
        pendingSemanticPlanChange = PendingSemanticPlanChange(
            signature: semanticSignature,
            firstObservedFrameNumber: frameNumber
        )
        return true
    }

    private func fixedPlan(
        logicalSize: MiragePixelSize,
        codec: MirageVideoCodec
    ) -> MirageMosaicTilePlan {
        planner.plan(for: StreamContextMosaicTilePlanRequest(
            logicalSize: logicalSize,
            codec: codec
        ))
    }

    private func semanticSignature(
        for candidates: [StreamContextMosaicSemanticCandidate]
    ) -> [SemanticCandidateSignature] {
        candidates.filter {
            $0.isReliable && !$0.rect.size.isEmpty && Self.isSemanticTileClass($0.semanticClass)
        }
        .sorted(by: Self.planningOrder)
        .prefix(max(0, planner.maxSemanticTiles))
        .map { candidate in
            SemanticCandidateSignature(
                semanticClass: candidate.semanticClass,
                priority: candidate.priority,
                rect: QuantizedRect(candidate.rect),
                codecStrategy: candidate.codecStrategy,
                commitPolicy: candidate.commitPolicy
            )
        }
        .sorted()
    }

    private static func planningOrder(
        lhs: StreamContextMosaicSemanticCandidate,
        rhs: StreamContextMosaicSemanticCandidate
    ) -> Bool {
        if lhs.parentID == rhs.id { return true }
        if rhs.parentID == lhs.id { return false }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        let lhsArea = lhs.rect.width * lhs.rect.height
        let rhsArea = rhs.rect.width * rhs.rect.height
        if lhsArea != rhsArea { return lhsArea < rhsArea }
        return lhs.id < rhs.id
    }

    private static func isSemanticTileClass(_ semanticClass: MirageMosaicSemanticClass) -> Bool {
        switch semanticClass {
        case .scrollView,
             .textViewport:
            true
        default:
            false
        }
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
