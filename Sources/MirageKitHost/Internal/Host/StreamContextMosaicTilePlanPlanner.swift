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
    let parentID: MirageMosaicTileID?
    let codecStrategy: MirageMosaicCodecStrategy
    let commitPolicy: MirageMosaicCommitPolicy
    let isReliable: Bool

    init(
        id: MirageMosaicTileID,
        rect: MiragePixelRect,
        semanticClass: MirageMosaicSemanticClass,
        priority: MirageMosaicTilePriority,
        parentID: MirageMosaicTileID? = nil,
        codecStrategy: MirageMosaicCodecStrategy = .singleUnit,
        commitPolicy: MirageMosaicCommitPolicy = .independent,
        isReliable: Bool
    ) {
        self.id = id
        self.rect = rect
        self.semanticClass = semanticClass
        self.priority = priority
        self.parentID = parentID
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
    let maxSemanticTiles: Int
    let minFallbackTileSize: MiragePixelSize
    let maxFallbackTileSize: MiragePixelSize

    init(
        maxSemanticTiles: Int = 12,
        minFallbackTileSize: MiragePixelSize = MiragePixelSize(width: 320, height: 180),
        maxFallbackTileSize: MiragePixelSize = MiragePixelSize(width: 1536, height: 1024)
    ) {
        self.maxSemanticTiles = max(0, maxSemanticTiles)
        self.minFallbackTileSize = minFallbackTileSize
        self.maxFallbackTileSize = maxFallbackTileSize
    }

    func plan(for request: StreamContextMosaicTilePlanRequest) -> MirageMosaicTilePlan {
        if request.isTransientSystemState,
           request.semanticCandidates.isEmpty,
           let previousPlan = request.previousPlan,
           previousPlan.logicalSize == request.logicalSize {
            return previousPlan
        }

        let reliableCandidates = request.semanticCandidates
            .filter { $0.isReliable && !$0.rect.size.isEmpty && Self.isSemanticTileClass($0.semanticClass) }
            .sorted(by: Self.planningOrder)
        guard !reliableCandidates.isEmpty,
              maxSemanticTiles > 0 else {
            return fixedGridPlan(for: request)
        }

        var occupiedRects: [MiragePixelRect] = []
        var tiles: [MirageMosaicTileDescriptor] = []
        let semanticTileBudget = max(0, maxSemanticTiles)
        for candidate in reliableCandidates {
            guard tiles.count < semanticTileBudget else { break }
            let clipped = Self.clamped(candidate.rect, to: request.logicalSize)
            let fragments = Self.subtract(occupiedRects, from: clipped)
                .filter { !Self.isTiny($0, minimumWidth: 48, minimumHeight: 32) }
            for (fragmentIndex, fragment) in fragments.enumerated() {
                guard tiles.count < semanticTileBudget else { break }
                let expandedFragments = Self.expandedFragments(fragment, strategy: candidate.codecStrategy)
                for (subtileIndex, expandedFragment) in expandedFragments.enumerated() {
                    guard tiles.count < semanticTileBudget else { break }
                    let tileID = Self.tileID(
                        for: candidate,
                        fragmentCount: fragments.count,
                        fragmentIndex: fragmentIndex,
                        subtileCount: expandedFragments.count,
                        subtileIndex: subtileIndex
                    )
                    tiles.append(MirageMosaicTileDescriptor(
                        id: tileID,
                        sourceRect: expandedFragment,
                        presentationRect: expandedFragment,
                        semanticClass: candidate.semanticClass,
                        priority: candidate.priority,
                        parentTileID: candidate.parentID ?? (expandedFragments.count > 1 ? candidate.id : nil),
                        subtileIndex: expandedFragments.count > 1 ? subtileIndex : nil,
                        codecStrategy: candidate.codecStrategy,
                        transportGroupID: MirageMosaicTransportGroupID(rawValue: candidate.id.rawValue),
                        presentationGroupID: MirageMosaicPresentationGroupID(rawValue: candidate.id.rawValue),
                        commitPolicy: candidate.commitPolicy
                    ))
                    occupiedRects.append(expandedFragment)
                }
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
        let bounds = MiragePixelRect(size: request.logicalSize)
        let tiles = splitFallbackTile(bounds).map { rect in
            let tileID = MirageMosaicTileID(rawValue: [
                "grid",
                "\(rect.x)",
                "\(rect.y)",
                "\(rect.width)",
                "\(rect.height)",
            ].joined(separator: "-"))
            return MirageMosaicTileDescriptor(
                id: tileID,
                sourceRect: rect,
                presentationRect: rect,
                semanticClass: .gridFallback,
                priority: .gridFallback
            )
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
            kind: .fixedGrid,
            logicalSize: request.logicalSize,
            tiles: tiles,
            codecUnits: units
        )
    }

    private func fallbackFragments(
        for request: StreamContextMosaicTilePlanRequest,
        occupiedRects: [MiragePixelRect]
    ) -> [MirageMosaicTileDescriptor] {
        let bounds = MiragePixelRect(size: request.logicalSize)
        return Self.subtract(occupiedRects, from: bounds)
            .sorted(by: Self.residualOrder)
            .flatMap { splitFallbackTile($0) }
            .map { fragment in
                let tileID = MirageMosaicTileID(rawValue: [
                    "fallback",
                    "\(fragment.x)",
                    "\(fragment.y)",
                    "\(fragment.width)",
                    "\(fragment.height)",
                ].joined(separator: "-"))
                return MirageMosaicTileDescriptor(
                    id: tileID,
                    sourceRect: fragment,
                    presentationRect: fragment,
                    semanticClass: .gridFallback,
                    priority: .gridFallback,
                    codecStrategy: .singleUnit,
                    commitPolicy: .independent
                )
            }
    }

    private func splitFallbackTile(_ rect: MiragePixelRect) -> [MiragePixelRect] {
        guard !rect.size.isEmpty else { return [] }
        let columnCount = Self.splitCount(
            length: rect.width,
            maximum: maxFallbackTileSize.width,
            minimum: minFallbackTileSize.width
        )
        let rowCount = Self.splitCount(
            length: rect.height,
            maximum: maxFallbackTileSize.height,
            minimum: minFallbackTileSize.height
        )
        guard columnCount > 1 || rowCount > 1 else { return [rect] }
        return (0 ..< rowCount).flatMap { row in
            (0 ..< columnCount).map { column in
                let x0 = rect.x + column * rect.width / columnCount
                let x1 = rect.x + (column + 1) * rect.width / columnCount
                let y0 = rect.y + row * rect.height / rowCount
                let y1 = rect.y + (row + 1) * rect.height / rowCount
                return MiragePixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
        }
    }

    private static func splitCount(length: Int, maximum: Int, minimum: Int) -> Int {
        let maximum = max(1, maximum)
        let minimum = max(1, minimum)
        var count = max(1, Int(ceil(Double(length) / Double(maximum))))
        while count > 1, length / count < minimum {
            count -= 1
        }
        return count
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

    private static func expandedFragments(
        _ rect: MiragePixelRect,
        strategy: MirageMosaicCodecStrategy
    ) -> [MiragePixelRect] {
        switch strategy {
        case .gridChildren:
            return gridChildren(in: rect)
        case .singleUnit,
             .verticalColumns,
             .horizontalBands,
             .retainedTransformStrips,
             .coalescedSupertile,
             .chromeAtlas:
            return [rect]
        }
    }

    private static func residualOrder(_ lhs: MiragePixelRect, _ rhs: MiragePixelRect) -> Bool {
        let lhsArea = lhs.width * lhs.height
        let rhsArea = rhs.width * rhs.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.x < rhs.x
    }

    private static func gridChildren(in rect: MiragePixelRect) -> [MiragePixelRect] {
        guard rect.width >= 1200, rect.height >= 900 else { return [rect] }
        let columns = 2
        let rows = 2
        return (0 ..< rows).flatMap { row in
            (0 ..< columns).map { column in
                let x0 = rect.x + column * rect.width / columns
                let x1 = rect.x + (column + 1) * rect.width / columns
                let y0 = rect.y + row * rect.height / rows
                let y1 = rect.y + (row + 1) * rect.height / rows
                return MiragePixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
        }
        .filter { !isTiny($0) }
    }

    private static func tileID(
        for candidate: StreamContextMosaicSemanticCandidate,
        fragmentCount: Int,
        fragmentIndex: Int,
        subtileCount: Int,
        subtileIndex: Int
    ) -> MirageMosaicTileID {
        guard fragmentCount > 1 || subtileCount > 1 else { return candidate.id }
        var components = [candidate.id.rawValue]
        if fragmentCount > 1 {
            components.append("part-\(fragmentIndex)")
        }
        if subtileCount > 1 {
            components.append("sub-\(subtileIndex)")
        }
        return MirageMosaicTileID(rawValue: components.joined(separator: "-"))
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

    private static func isTiny(
        _ rect: MiragePixelRect,
        minimumWidth: Int = 16,
        minimumHeight: Int = 16
    ) -> Bool {
        rect.width < minimumWidth || rect.height < minimumHeight
    }
}

#endif
