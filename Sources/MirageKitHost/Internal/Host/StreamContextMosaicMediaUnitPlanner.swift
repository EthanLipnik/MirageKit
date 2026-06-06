//
//  StreamContextMosaicMediaUnitPlanner.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/6/26.
//

import CoreGraphics
import Foundation
import MirageMedia

#if os(macOS)

struct StreamContextMosaicMediaUnitWorkItem: Sendable, Equatable {
    let plan: MirageMosaicTilePlan
    let tile: MirageMosaicTileDescriptor
    let codecUnit: MirageMosaicCodecUnitDescriptor
    let mediaUnitIndex: UInt16
    let tileIndex: UInt16
    let transportGroupIndex: UInt16
    let presentationGroupIndex: UInt16
    let tileVersion: UInt32
    let dependencyVersion: UInt32?
    let isDirty: Bool

    var sourceCGRect: CGRect {
        CGRect(
            x: CGFloat(codecUnit.sourceRect.x),
            y: CGFloat(codecUnit.sourceRect.y),
            width: CGFloat(codecUnit.sourceRect.width),
            height: CGFloat(codecUnit.sourceRect.height)
        )
    }

    func senderMetadata(unitFrameNumber: UInt32) -> StreamPacketSender.MosaicMediaUnitMetadata {
        StreamPacketSender.MosaicMediaUnitMetadata(
            tilePlanEpoch: plan.epoch,
            mediaEpoch: unitFrameNumber,
            mediaUnitIndex: mediaUnitIndex,
            tileIndex: tileIndex,
            transportGroupIndex: transportGroupIndex,
            presentationGroupIndex: presentationGroupIndex,
            tileVersion: tileVersion,
            dependencyVersion: dependencyVersion
        )
    }
}

struct StreamContextMosaicMediaUnitPlanner: Sendable {
    func plannedUnits(
        plan: MirageMosaicTilePlan,
        summary: MirageMosaicEpochSummary?,
        includeCleanUnits: Bool = false
    ) -> [StreamContextMosaicMediaUnitWorkItem] {
        guard !plan.tiles.isEmpty,
              !plan.codecUnits.isEmpty else {
            return []
        }

        let tileIndices = Dictionary(uniqueKeysWithValues: plan.tiles.enumerated().map { index, tile in
            (tile.id, UInt16(clamping: index))
        })
        let mediaUnitIndices = Dictionary(uniqueKeysWithValues: plan.codecUnits.enumerated().map { index, unit in
            (unit.id, UInt16(clamping: index))
        })
        let transportGroupIndices = Self.groupIndices(plan.tiles.map(\.transportGroupID))
        let presentationGroupIndices = Self.groupIndices(plan.tiles.map(\.presentationGroupID))
        let dirtyTileIDs = Set(summary?.dirtyTileIDs ?? plan.tiles.map(\.id))

        let units = plan.codecUnits.compactMap { unit -> StreamContextMosaicMediaUnitWorkItem? in
            guard let tile = plan.tile(for: unit.tileID),
                  let mediaUnitIndex = mediaUnitIndices[unit.id],
                  let tileIndex = tileIndices[tile.id],
                  let transportGroupIndex = transportGroupIndices[unit.transportGroupID],
                  let presentationGroupIndex = presentationGroupIndices[unit.presentationGroupID] else {
                return nil
            }
            let unitTileIDs = unit.coalescedTileIDs.isEmpty ? [unit.tileID] : unit.coalescedTileIDs
            let isDirty = unitTileIDs.contains { dirtyTileIDs.contains($0) }
            guard isDirty || includeCleanUnits else { return nil }

            let tileVersion = Self.tileVersion(
                tileIDs: unitTileIDs,
                summary: summary
            )
            let dependencyVersion = Self.dependencyVersion(
                tileIDs: unitTileIDs,
                summary: summary,
                isDirty: isDirty
            )
            return StreamContextMosaicMediaUnitWorkItem(
                plan: plan,
                tile: tile,
                codecUnit: unit,
                mediaUnitIndex: mediaUnitIndex,
                tileIndex: tileIndex,
                transportGroupIndex: transportGroupIndex,
                presentationGroupIndex: presentationGroupIndex,
                tileVersion: tileVersion,
                dependencyVersion: dependencyVersion,
                isDirty: isDirty
            )
        }

        return units.sorted { lhs, rhs in
            if lhs.tile.priority != rhs.tile.priority { return lhs.tile.priority < rhs.tile.priority }
            if lhs.transportGroupIndex != rhs.transportGroupIndex {
                return lhs.transportGroupIndex < rhs.transportGroupIndex
            }
            if lhs.presentationGroupIndex != rhs.presentationGroupIndex {
                return lhs.presentationGroupIndex < rhs.presentationGroupIndex
            }
            return lhs.mediaUnitIndex < rhs.mediaUnitIndex
        }
    }

    private static func tileVersion(
        tileIDs: [MirageMosaicTileID],
        summary: MirageMosaicEpochSummary?
    ) -> UInt32 {
        guard let summary else { return 0 }
        let versions = tileIDs.compactMap { tileID in
            summary.updatedTileVersions[tileID] ?? summary.reusedTileVersions[tileID]
        }
        return versions.max() ?? 0
    }

    private static func dependencyVersion(
        tileIDs: [MirageMosaicTileID],
        summary: MirageMosaicEpochSummary?,
        isDirty: Bool
    ) -> UInt32? {
        guard isDirty, let summary else { return nil }
        let previousVersions = tileIDs.compactMap { tileID -> UInt32? in
            if let updated = summary.updatedTileVersions[tileID] {
                return updated > 0 ? updated - 1 : 0
            }
            return summary.reusedTileVersions[tileID]
        }
        return previousVersions.max()
    }

    private static func groupIndices<T: Comparable & Hashable>(_ groups: [T]) -> [T: UInt16] {
        Dictionary(uniqueKeysWithValues: Array(Set(groups)).sorted().enumerated().map { index, group in
            (group, UInt16(clamping: index))
        })
    }
}

#endif
