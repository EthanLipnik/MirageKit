//
//  MirageMosaicTilePlan.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/6/26.
//

import Foundation

public struct MirageMosaicTileID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? "tile-0" : trimmed
    }

    public static func < (lhs: MirageMosaicTileID, rhs: MirageMosaicTileID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct MirageMosaicCodecUnitID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? MirageMediaUnitID.primary.rawValue : trimmed
    }

    public var mediaUnitID: MirageMediaUnitID {
        MirageMediaUnitID(rawValue: rawValue)
    }

    public static func < (lhs: MirageMosaicCodecUnitID, rhs: MirageMosaicCodecUnitID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct MirageMosaicTransportGroupID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? "transport-primary" : trimmed
    }

    public static func < (lhs: MirageMosaicTransportGroupID, rhs: MirageMosaicTransportGroupID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct MirageMosaicPresentationGroupID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? "presentation-primary" : trimmed
    }

    public static func < (lhs: MirageMosaicPresentationGroupID, rhs: MirageMosaicPresentationGroupID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum MirageMosaicTilePlanKind: String, CaseIterable, Codable, Sendable {
    case semantic
    case fixedGrid
    case coarseGrid
    case chromeAtlas
}

public enum MirageMosaicSemanticClass: String, CaseIterable, Codable, Sendable {
    case unknown
    case gridFallback
    case menuBar
    case dock
    case focusedWindow
    case scrollView
    case textViewport
    case toolbar
    case sidebar
    case popover
    case sheet
    case menu
    case canvas
    case video
    case background
    case chromeAtlas

    public var isTextSensitive: Bool {
        switch self {
        case .textViewport,
             .scrollView:
            true
        default:
            false
        }
    }
}

public enum MirageMosaicTilePriority: Int, CaseIterable, Codable, Sendable, Comparable {
    case recovery = 0
    case activeInput = 10
    case focusedContent = 20
    case transientChrome = 30
    case semanticContent = 40
    case gridFallback = 50
    case periodicRefresh = 60

    public static func < (lhs: MirageMosaicTilePriority, rhs: MirageMosaicTilePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum MirageMosaicCodecStrategy: String, CaseIterable, Codable, Sendable {
    case singleUnit
    case verticalColumns
    case horizontalBands
    case gridChildren
    case retainedTransformStrips
    case coalescedSupertile
    case chromeAtlas
}

public enum MirageMosaicCommitPolicy: String, CaseIterable, Codable, Sendable {
    case independent
    case atomic
    case partialAllowed
}

public struct MirageMosaicTileDescriptor: Hashable, Codable, Sendable {
    public let id: MirageMosaicTileID
    public let sourceRect: MiragePixelRect
    public let presentationRect: MiragePixelRect
    public let semanticClass: MirageMosaicSemanticClass
    public let priority: MirageMosaicTilePriority
    public let parentTileID: MirageMosaicTileID?
    public let subtileIndex: Int?
    public let codecStrategy: MirageMosaicCodecStrategy
    public let transportGroupID: MirageMosaicTransportGroupID
    public let presentationGroupID: MirageMosaicPresentationGroupID
    public let commitPolicy: MirageMosaicCommitPolicy
    public let textSensitive: Bool

    public init(
        id: MirageMosaicTileID,
        sourceRect: MiragePixelRect,
        presentationRect: MiragePixelRect,
        semanticClass: MirageMosaicSemanticClass,
        priority: MirageMosaicTilePriority,
        parentTileID: MirageMosaicTileID? = nil,
        subtileIndex: Int? = nil,
        codecStrategy: MirageMosaicCodecStrategy = .singleUnit,
        transportGroupID: MirageMosaicTransportGroupID? = nil,
        presentationGroupID: MirageMosaicPresentationGroupID? = nil,
        commitPolicy: MirageMosaicCommitPolicy = .independent,
        textSensitive: Bool? = nil
    ) {
        self.id = id
        self.sourceRect = sourceRect
        self.presentationRect = presentationRect
        self.semanticClass = semanticClass
        self.priority = priority
        self.parentTileID = parentTileID
        self.subtileIndex = subtileIndex.map { max(0, $0) }
        self.codecStrategy = codecStrategy
        self.transportGroupID = transportGroupID ?? MirageMosaicTransportGroupID(rawValue: id.rawValue)
        self.presentationGroupID = presentationGroupID ?? MirageMosaicPresentationGroupID(rawValue: id.rawValue)
        self.commitPolicy = commitPolicy
        self.textSensitive = textSensitive ?? semanticClass.isTextSensitive
    }
}

public struct MirageMosaicCodecUnitDescriptor: Hashable, Codable, Sendable {
    public let id: MirageMosaicCodecUnitID
    public let tileID: MirageMosaicTileID
    public let sourceRect: MiragePixelRect
    public let presentationRect: MiragePixelRect
    public let encodedSize: MiragePixelSize
    public let codec: MirageVideoCodec
    public let dependencyScope: MirageMediaDependencyScope
    public let transportGroupID: MirageMosaicTransportGroupID
    public let presentationGroupID: MirageMosaicPresentationGroupID
    public let commitPolicy: MirageMosaicCommitPolicy
    public let coalescedTileIDs: [MirageMosaicTileID]

    public init(
        id: MirageMosaicCodecUnitID,
        tileID: MirageMosaicTileID,
        sourceRect: MiragePixelRect,
        presentationRect: MiragePixelRect,
        encodedSize: MiragePixelSize,
        codec: MirageVideoCodec,
        dependencyScope: MirageMediaDependencyScope = .independent,
        transportGroupID: MirageMosaicTransportGroupID,
        presentationGroupID: MirageMosaicPresentationGroupID,
        commitPolicy: MirageMosaicCommitPolicy,
        coalescedTileIDs: [MirageMosaicTileID] = []
    ) {
        self.id = id
        self.tileID = tileID
        self.sourceRect = sourceRect
        self.presentationRect = presentationRect
        self.encodedSize = encodedSize.isEmpty ? sourceRect.size : encodedSize
        self.codec = codec
        self.dependencyScope = dependencyScope
        self.transportGroupID = transportGroupID
        self.presentationGroupID = presentationGroupID
        self.commitPolicy = commitPolicy
        self.coalescedTileIDs = coalescedTileIDs.isEmpty ? [tileID] : Array(Set(coalescedTileIDs)).sorted()
    }
}

public struct MirageMosaicTilePlan: Hashable, Codable, Sendable {
    public let id: MirageMediaTopologyID
    public let epoch: UInt32
    public let kind: MirageMosaicTilePlanKind
    public let logicalSize: MiragePixelSize
    public let tiles: [MirageMosaicTileDescriptor]
    public let codecUnits: [MirageMosaicCodecUnitDescriptor]

    public init(
        id: MirageMediaTopologyID = MirageMediaTopologyID(),
        epoch: UInt32 = 0,
        kind: MirageMosaicTilePlanKind,
        logicalSize: MiragePixelSize,
        tiles: [MirageMosaicTileDescriptor],
        codecUnits: [MirageMosaicCodecUnitDescriptor]
    ) {
        self.id = id
        self.epoch = epoch
        self.kind = kind
        self.logicalSize = logicalSize
        self.tiles = tiles.filter { !$0.sourceRect.size.isEmpty && !$0.presentationRect.size.isEmpty }
        let tileIDs = Set(self.tiles.map(\.id))
        self.codecUnits = codecUnits.filter {
            tileIDs.contains($0.tileID) &&
                !$0.sourceRect.size.isEmpty &&
                !$0.presentationRect.size.isEmpty &&
                !$0.encodedSize.isEmpty
        }
    }

    public static func fixedGrid(
        id: MirageMediaTopologyID = MirageMediaTopologyID(),
        epoch: UInt32 = 0,
        logicalSize: MiragePixelSize,
        columns: Int,
        rows: Int,
        codec: MirageVideoCodec
    ) -> MirageMosaicTilePlan {
        let columnCount = max(1, columns)
        let rowCount = max(1, rows)
        let tileRects = Self.partition(logicalSize: logicalSize, columns: columnCount, rows: rowCount)
        let tiles = tileRects.enumerated().map { index, rect in
            let tileID = MirageMosaicTileID(rawValue: "grid-\(index)")
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
                codec: codec,
                transportGroupID: tile.transportGroupID,
                presentationGroupID: tile.presentationGroupID,
                commitPolicy: tile.commitPolicy
            )
        }
        return MirageMosaicTilePlan(
            id: id,
            epoch: epoch,
            kind: .fixedGrid,
            logicalSize: logicalSize,
            tiles: tiles,
            codecUnits: units
        )
    }

    public var mediaTopology: MirageMediaTopology {
        MirageMediaTopology(
            id: id,
            kind: .mosaic,
            logicalSize: logicalSize,
            units: codecUnits.map { unit in
                MirageMediaUnitDescriptor(
                    id: unit.id.mediaUnitID,
                    sourceRect: unit.sourceRect,
                    presentationRect: unit.presentationRect,
                    codec: unit.codec,
                    dependencyScope: unit.dependencyScope
                )
            }
        )
    }

    public func codecUnit(for id: MirageMosaicCodecUnitID) -> MirageMosaicCodecUnitDescriptor? {
        codecUnits.first { $0.id == id }
    }

    public func tile(for id: MirageMosaicTileID) -> MirageMosaicTileDescriptor? {
        tiles.first { $0.id == id }
    }

    private static func partition(logicalSize: MiragePixelSize, columns: Int, rows: Int) -> [MiragePixelRect] {
        guard !logicalSize.isEmpty else { return [] }
        let alignedWidth = max(1, logicalSize.width)
        let alignedHeight = max(1, logicalSize.height)
        var rects: [MiragePixelRect] = []
        for row in 0 ..< rows {
            let y0 = row * alignedHeight / rows
            let y1 = (row + 1) * alignedHeight / rows
            for column in 0 ..< columns {
                let x0 = column * alignedWidth / columns
                let x1 = (column + 1) * alignedWidth / columns
                rects.append(MiragePixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }
        return rects
    }
}
