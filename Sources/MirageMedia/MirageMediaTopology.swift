//
//  MirageMediaTopology.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Stable identifier for one media topology description.
public struct MirageMediaTopologyID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Stable identifier for one media unit inside a topology.
public struct MirageMediaUnitID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? Self.primary.rawValue : trimmed
    }

    /// Default unit identifier for current full-frame streams.
    public static let primary = MirageMediaUnitID(rawValue: "primary")
}

/// Pixel dimensions used by topology descriptors.
public struct MiragePixelSize: Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var isEmpty: Bool {
        width == 0 || height == 0
    }
}

/// Pixel-aligned rectangle used by topology descriptors.
public struct MiragePixelRect: Hashable, Codable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = max(0, x)
        self.y = max(0, y)
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public init(originX: Int = 0, originY: Int = 0, size: MiragePixelSize) {
        self.init(x: originX, y: originY, width: size.width, height: size.height)
    }

    public var size: MiragePixelSize {
        MiragePixelSize(width: width, height: height)
    }
}

/// Topology family used to describe how encoded media units compose a stream.
public enum MirageMediaTopologyKind: String, CaseIterable, Codable, Sendable {
    case singleUnit
    case atlas
    case multiUnit
    case replay
}

/// Dependency scope for one media unit within a topology.
public enum MirageMediaDependencyScope: String, Codable, Sendable {
    /// Unit can be decoded and recovered independently.
    case independent
    /// Unit depends on another unit in the same topology.
    case dependent
}

/// Description of one encoded media unit inside a topology.
public struct MirageMediaUnitDescriptor: Hashable, Codable, Sendable {
    public let id: MirageMediaUnitID
    public let sourceRect: MiragePixelRect
    public let presentationRect: MiragePixelRect
    public let codec: MirageVideoCodec
    public let dependencyScope: MirageMediaDependencyScope

    public init(
        id: MirageMediaUnitID,
        sourceRect: MiragePixelRect,
        presentationRect: MiragePixelRect,
        codec: MirageVideoCodec,
        dependencyScope: MirageMediaDependencyScope = .independent
    ) {
        self.id = id
        self.sourceRect = sourceRect
        self.presentationRect = presentationRect
        self.codec = codec
        self.dependencyScope = dependencyScope
    }
}

/// Stable description of the media units that compose one stream.
public struct MirageMediaTopology: Hashable, Codable, Sendable {
    public let id: MirageMediaTopologyID
    public let kind: MirageMediaTopologyKind
    public let logicalSize: MiragePixelSize
    public let units: [MirageMediaUnitDescriptor]

    public init(
        id: MirageMediaTopologyID = MirageMediaTopologyID(),
        kind: MirageMediaTopologyKind,
        logicalSize: MiragePixelSize,
        units: [MirageMediaUnitDescriptor]
    ) {
        self.id = id
        self.kind = kind
        self.logicalSize = logicalSize
        self.units = units
    }

    /// Creates the topology that represents today's full-frame stream behavior.
    public static func singleUnit(
        id: MirageMediaTopologyID = MirageMediaTopologyID(),
        unitID: MirageMediaUnitID = .primary,
        logicalSize: MiragePixelSize,
        codec: MirageVideoCodec
    ) -> MirageMediaTopology {
        let fullFrame = MiragePixelRect(size: logicalSize)
        return MirageMediaTopology(
            id: id,
            kind: .singleUnit,
            logicalSize: logicalSize,
            units: [
                MirageMediaUnitDescriptor(
                    id: unitID,
                    sourceRect: fullFrame,
                    presentationRect: fullFrame,
                    codec: codec,
                    dependencyScope: .independent
                ),
            ]
        )
    }

    /// Returns whether this topology exactly describes one full-frame media unit.
    public var representsSingleUnitFullFrame: Bool {
        guard kind == .singleUnit, units.count == 1, let unit = units.first else {
            return false
        }
        let fullFrame = MiragePixelRect(size: logicalSize)
        return unit.sourceRect == fullFrame &&
            unit.presentationRect == fullFrame &&
            unit.dependencyScope == .independent
    }
}
