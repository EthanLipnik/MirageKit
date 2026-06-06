//
//  StreamContextMosaicTilePlanPlanner.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/6/26.
//

import Foundation
import MirageMedia

#if os(macOS)

struct StreamContextMosaicSemanticCandidate: Sendable, Equatable {
    let id: MirageMosaicTileID
    let rect: MiragePixelRect
    let semanticClass: MirageMosaicSemanticClass
    let priority: MirageMosaicTilePriority
    let codecStrategy: MirageMosaicCodecStrategy
    let commitPolicy: MirageMosaicCommitPolicy
    let isReliable: Bool

    init(
        id: MirageMosaicTileID,
        rect: MiragePixelRect,
        semanticClass: MirageMosaicSemanticClass,
        priority: MirageMosaicTilePriority,
        codecStrategy: MirageMosaicCodecStrategy = .singleUnit,
        commitPolicy: MirageMosaicCommitPolicy = .independent,
        isReliable: Bool
    ) {
        self.id = id
        self.rect = rect
        self.semanticClass = semanticClass
        self.priority = priority
        self.codecStrategy = codecStrategy
        self.commitPolicy = commitPolicy
        self.isReliable = isReliable
    }
}

struct StreamContextMosaicTilePlanRequest: Sendable, Equatable {
    let logicalSize: MiragePixelSize
    let codec: MirageVideoCodec
    let semanticCandidates: [StreamContextMosaicSemanticCandidate]
    let isTransientSystemState: Bool
    let previousPlan: MirageMosaicTilePlan?

    init(
        logicalSize: MiragePixelSize,
        codec: MirageVideoCodec,
        semanticCandidates: [StreamContextMosaicSemanticCandidate] = [],
        isTransientSystemState: Bool = false,
        previousPlan: MirageMosaicTilePlan? = nil
    ) {
        self.logicalSize = logicalSize
        self.codec = codec
        self.semanticCandidates = semanticCandidates
        self.isTransientSystemState = isTransientSystemState
        self.previousPlan = previousPlan
    }
}

struct StreamContextMosaicTilePlanPlanner: Sendable {
    let fallbackColumns: Int
    let fallbackRows: Int

    init(fallbackColumns: Int = 3, fallbackRows: Int = 3) {
        self.fallbackColumns = max(1, fallbackColumns)
        self.fallbackRows = max(1, fallbackRows)
    }

    func plan(for request: StreamContextMosaicTilePlanRequest) -> MirageMosaicTilePlan {
        if request.isTransientSystemState,
           let previousPlan = request.previousPlan,
           previousPlan.logicalSize == request.logicalSize {
            return previousPlan
        }

        let reliableCandidates = request.semanticCandidates
            .filter { $0.isReliable && !$0.rect.size.isEmpty }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.id < rhs.id
            }
        guard !reliableCandidates.isEmpty else {
            return fixedGridPlan(for: request)
        }

        var occupiedRects: [MiragePixelRect] = []
        var tiles: [MirageMosaicTileDescriptor] = []
        for candidate in reliableCandidates {
            let clipped = Self.clamped(candidate.rect, to: request.logicalSize)
            let fragments = Self.subtract(occupiedRects, from: clipped)
                .filter { !Self.isTiny($0) }
            for (fragmentIndex, fragment) in fragments.enumerated() {
                let tileID = fragments.count == 1
                    ? candidate.id
                    : MirageMosaicTileID(rawValue: "\(candidate.id.rawValue)-part-\(fragmentIndex)")
                tiles.append(MirageMosaicTileDescriptor(
                    id: tileID,
                    sourceRect: fragment,
                    presentationRect: fragment,
                    semanticClass: candidate.semanticClass,
                    priority: candidate.priority,
                    codecStrategy: candidate.codecStrategy,
                    transportGroupID: MirageMosaicTransportGroupID(rawValue: candidate.id.rawValue),
                    presentationGroupID: MirageMosaicPresentationGroupID(rawValue: candidate.id.rawValue),
                    commitPolicy: candidate.commitPolicy
                ))
                occupiedRects.append(fragment)
            }
        }

        for fallback in fallbackFragments(for: request, occupiedRects: occupiedRects) {
            tiles.append(fallback)
            occupiedRects.append(fallback.sourceRect)
        }

        let units = tiles.map { tile in
            MirageMosaicCodecUnitDescriptor(
                id: MirageMosaicCodecUnitID(rawValue: tile.id.rawValue),
                tileID: tile.id,
                sourceRect: tile.sourceRect,
                presentationRect: tile.presentationRect,
                encodedSize: tile.sourceRect.size,
                codec: request.codec,
                transportGroupID: tile.transportGroupID,
                presentationGroupID: tile.presentationGroupID,
                commitPolicy: tile.commitPolicy
            )
        }
        return MirageMosaicTilePlan(
            kind: .semantic,
            logicalSize: request.logicalSize,
            tiles: tiles,
            codecUnits: units
        )
    }

    private func fixedGridPlan(for request: StreamContextMosaicTilePlanRequest) -> MirageMosaicTilePlan {
        MirageMosaicTilePlan.fixedGrid(
            logicalSize: request.logicalSize,
            columns: fallbackColumns,
            rows: fallbackRows,
            codec: request.codec
        )
    }

    private func fallbackFragments(
        for request: StreamContextMosaicTilePlanRequest,
        occupiedRects: [MiragePixelRect]
    ) -> [MirageMosaicTileDescriptor] {
        let gridPlan = fixedGridPlan(for: request)
        var tiles: [MirageMosaicTileDescriptor] = []
        for gridTile in gridPlan.tiles {
            let fragments = Self.subtract(occupiedRects, from: gridTile.sourceRect)
                .filter { !Self.isTiny($0) }
            for (fragmentIndex, fragment) in fragments.enumerated() {
                let tileID = fragments.count == 1
                    ? MirageMosaicTileID(rawValue: "fallback-\(gridTile.id.rawValue)")
                    : MirageMosaicTileID(rawValue: "fallback-\(gridTile.id.rawValue)-part-\(fragmentIndex)")
                tiles.append(MirageMosaicTileDescriptor(
                    id: tileID,
                    sourceRect: fragment,
                    presentationRect: fragment,
                    semanticClass: .gridFallback,
                    priority: .gridFallback,
                    codecStrategy: .singleUnit,
                    commitPolicy: .independent
                ))
            }
        }
        return tiles
    }

    private static func subtract(_ cutters: [MiragePixelRect], from rect: MiragePixelRect) -> [MiragePixelRect] {
        cutters.reduce([rect]) { fragments, cutter in
            fragments.flatMap { subtract(cutter, from: $0) }
        }
    }

    private static func subtract(_ cutter: MiragePixelRect, from rect: MiragePixelRect) -> [MiragePixelRect] {
        guard let intersection = intersection(rect, cutter) else { return [rect] }
        var fragments: [MiragePixelRect] = []
        let rectMaxX = rect.x + rect.width
        let rectMaxY = rect.y + rect.height
        let intersectionMaxX = intersection.x + intersection.width
        let intersectionMaxY = intersection.y + intersection.height

        if rect.y < intersection.y {
            fragments.append(MiragePixelRect(
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: intersection.y - rect.y
            ))
        }
        if intersectionMaxY < rectMaxY {
            fragments.append(MiragePixelRect(
                x: rect.x,
                y: intersectionMaxY,
                width: rect.width,
                height: rectMaxY - intersectionMaxY
            ))
        }
        if rect.x < intersection.x {
            fragments.append(MiragePixelRect(
                x: rect.x,
                y: intersection.y,
                width: intersection.x - rect.x,
                height: intersection.height
            ))
        }
        if intersectionMaxX < rectMaxX {
            fragments.append(MiragePixelRect(
                x: intersectionMaxX,
                y: intersection.y,
                width: rectMaxX - intersectionMaxX,
                height: intersection.height
            ))
        }
        return fragments.filter { !$0.size.isEmpty }
    }

    private static func intersection(_ lhs: MiragePixelRect, _ rhs: MiragePixelRect) -> MiragePixelRect? {
        let minX = max(lhs.x, rhs.x)
        let minY = max(lhs.y, rhs.y)
        let maxX = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let maxY = min(lhs.y + lhs.height, rhs.y + rhs.height)
        guard maxX > minX, maxY > minY else { return nil }
        return MiragePixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func clamped(_ rect: MiragePixelRect, to logicalSize: MiragePixelSize) -> MiragePixelRect {
        let bounds = MiragePixelRect(size: logicalSize)
        return intersection(rect, bounds) ?? MiragePixelRect(size: MiragePixelSize(width: 0, height: 0))
    }

    private static func isTiny(_ rect: MiragePixelRect) -> Bool {
        rect.width < 16 || rect.height < 16
    }
}

#endif
