//
//  MirageMosaicDirtyState.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/6/26.
//

import Foundation

/// Compact content signature for one planned Mosaic tile.
public struct MirageMosaicTileSignature: Hashable, Codable, Sendable {
    public let lumaHash: UInt64
    public let chromaHash: UInt64
    public let sampleCount: Int

    public init(lumaHash: UInt64, chromaHash: UInt64 = 0, sampleCount: Int = 1) {
        self.lumaHash = lumaHash
        self.chromaHash = chromaHash
        self.sampleCount = max(0, sampleCount)
    }

    public var isEmpty: Bool {
        sampleCount == 0
    }
}

public enum MirageMosaicTileDirtyReason: String, CaseIterable, Codable, Sendable {
    case firstObservation
    case planEpochChanged
    case captureMarkedDirty
    case signatureChanged
    case keyframeRequired
    case forcedRefresh
    case staleRefresh
}

/// Version state for a planned tile after one dirty-classification pass.
public struct MirageMosaicTileVersionState: Hashable, Codable, Sendable {
    public let tileID: MirageMosaicTileID
    public let version: UInt32
    public let signature: MirageMosaicTileSignature?
    public let lastUpdatedFrameNumber: UInt32

    public init(
        tileID: MirageMosaicTileID,
        version: UInt32,
        signature: MirageMosaicTileSignature?,
        lastUpdatedFrameNumber: UInt32
    ) {
        self.tileID = tileID
        self.version = version
        self.signature = signature?.isEmpty == true ? nil : signature
        self.lastUpdatedFrameNumber = lastUpdatedFrameNumber
    }
}

public struct MirageMosaicDirtyTileDecision: Hashable, Codable, Sendable {
    public let tileID: MirageMosaicTileID
    public let previousVersion: UInt32?
    public let nextVersion: UInt32
    public let isDirty: Bool
    public let reasons: [MirageMosaicTileDirtyReason]

    public init(
        tileID: MirageMosaicTileID,
        previousVersion: UInt32?,
        nextVersion: UInt32,
        isDirty: Bool,
        reasons: [MirageMosaicTileDirtyReason]
    ) {
        self.tileID = tileID
        self.previousVersion = previousVersion
        self.nextVersion = nextVersion
        self.isDirty = isDirty
        self.reasons = Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
    }
}

/// Small per-epoch state summary needed by a retained-tile compositor.
public struct MirageMosaicEpochSummary: Hashable, Codable, Sendable {
    public let tilePlanID: MirageMediaTopologyID
    public let tilePlanEpoch: UInt32
    public let frameNumber: UInt32
    public let dirtyTileIDs: [MirageMosaicTileID]
    public let reusedTileVersions: [MirageMosaicTileID: UInt32]
    public let updatedTileVersions: [MirageMosaicTileID: UInt32]

    public init(
        tilePlanID: MirageMediaTopologyID,
        tilePlanEpoch: UInt32,
        frameNumber: UInt32,
        dirtyTileIDs: [MirageMosaicTileID],
        reusedTileVersions: [MirageMosaicTileID: UInt32],
        updatedTileVersions: [MirageMosaicTileID: UInt32]
    ) {
        self.tilePlanID = tilePlanID
        self.tilePlanEpoch = tilePlanEpoch
        self.frameNumber = frameNumber
        self.dirtyTileIDs = Array(Set(dirtyTileIDs)).sorted()
        self.reusedTileVersions = reusedTileVersions
        self.updatedTileVersions = updatedTileVersions
    }
}

public struct MirageMosaicDirtyTileClassifierResult: Hashable, Codable, Sendable {
    public let summary: MirageMosaicEpochSummary
    public let decisions: [MirageMosaicDirtyTileDecision]

    public init(summary: MirageMosaicEpochSummary, decisions: [MirageMosaicDirtyTileDecision]) {
        self.summary = summary
        self.decisions = decisions.sorted { $0.tileID < $1.tileID }
    }
}

/// Stateful planned-tile dirty classifier.
public struct MirageMosaicDirtyTileClassifier: Sendable {
    public let staleRefreshFrameInterval: UInt32

    private var activePlanID: MirageMediaTopologyID?
    private var activePlanEpoch: UInt32?
    private var versionsByTileID: [MirageMosaicTileID: MirageMosaicTileVersionState] = [:]

    public init(staleRefreshFrameInterval: UInt32 = 0) {
        self.staleRefreshFrameInterval = staleRefreshFrameInterval
    }

    public mutating func reset() {
        activePlanID = nil
        activePlanEpoch = nil
        versionsByTileID.removeAll(keepingCapacity: false)
    }

    public mutating func classify(
        plan: MirageMosaicTilePlan,
        frameNumber: UInt32,
        signaturesByTileID: [MirageMosaicTileID: MirageMosaicTileSignature] = [:],
        captureMarkedDirtyTileIDs: Set<MirageMosaicTileID> = [],
        keyframeRequiredTileIDs: Set<MirageMosaicTileID> = [],
        forcedRefreshTileIDs: Set<MirageMosaicTileID> = []
    ) -> MirageMosaicDirtyTileClassifierResult {
        let planChanged = activePlanID != plan.id || activePlanEpoch != plan.epoch
        if planChanged {
            activePlanID = plan.id
            activePlanEpoch = plan.epoch
            versionsByTileID = versionsByTileID.filter { plan.tile(for: $0.key) != nil }
        }

        var decisions: [MirageMosaicDirtyTileDecision] = []
        var reusedTileVersions: [MirageMosaicTileID: UInt32] = [:]
        var updatedTileVersions: [MirageMosaicTileID: UInt32] = [:]

        for tile in plan.tiles.sorted(by: { $0.id < $1.id }) {
            let previous = versionsByTileID[tile.id]
            let signature = signaturesByTileID[tile.id].flatMap { $0.isEmpty ? nil : $0 }
            let isFirstObservation = previous == nil
            let signatureChanged = if let signature, let previousSignature = previous?.signature {
                signature != previousSignature
            } else {
                false
            }
            let staleRefresh = staleRefreshFrameInterval > 0 &&
                previous.map { frameNumber &- $0.lastUpdatedFrameNumber >= staleRefreshFrameInterval } == true

            var reasons: [MirageMosaicTileDirtyReason] = []
            if isFirstObservation { reasons.append(.firstObservation) }
            if planChanged { reasons.append(.planEpochChanged) }
            if captureMarkedDirtyTileIDs.contains(tile.id) { reasons.append(.captureMarkedDirty) }
            if signatureChanged { reasons.append(.signatureChanged) }
            if keyframeRequiredTileIDs.contains(tile.id) { reasons.append(.keyframeRequired) }
            if forcedRefreshTileIDs.contains(tile.id) { reasons.append(.forcedRefresh) }
            if staleRefresh { reasons.append(.staleRefresh) }

            let isDirty = !reasons.isEmpty
            let previousVersion = previous?.version
            let nextVersion = if isDirty {
                (previousVersion ?? 0) &+ 1
            } else {
                previousVersion ?? 0
            }
            let nextState = MirageMosaicTileVersionState(
                tileID: tile.id,
                version: nextVersion,
                signature: signature ?? previous?.signature,
                lastUpdatedFrameNumber: isDirty ? frameNumber : previous?.lastUpdatedFrameNumber ?? frameNumber
            )
            versionsByTileID[tile.id] = nextState
            if isDirty {
                updatedTileVersions[tile.id] = nextVersion
            } else {
                reusedTileVersions[tile.id] = nextVersion
            }
            decisions.append(MirageMosaicDirtyTileDecision(
                tileID: tile.id,
                previousVersion: previousVersion,
                nextVersion: nextVersion,
                isDirty: isDirty,
                reasons: reasons
            ))
        }

        let dirtyTileIDs = decisions.filter(\.isDirty).map(\.tileID)
        let summary = MirageMosaicEpochSummary(
            tilePlanID: plan.id,
            tilePlanEpoch: plan.epoch,
            frameNumber: frameNumber,
            dirtyTileIDs: dirtyTileIDs,
            reusedTileVersions: reusedTileVersions,
            updatedTileVersions: updatedTileVersions
        )
        return MirageMosaicDirtyTileClassifierResult(summary: summary, decisions: decisions)
    }
}
