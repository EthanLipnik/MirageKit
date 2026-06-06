//
//  MirageMediaTopologyTests.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageMedia
import Testing

@Suite("MirageMedia Topology")
struct MirageMediaTopologyTests {
    @Test("Single-unit topology represents current full-frame behavior")
    func singleUnitTopologyRepresentsCurrentFullFrameBehavior() throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "9D618F1E-1A77-4F62-8DAB-6A2D0BB3356A"))
        )
        let topology = MirageMediaTopology.singleUnit(
            id: topologyID,
            logicalSize: MiragePixelSize(width: 1920, height: 1080),
            codec: .hevc
        )

        #expect(topology.id == topologyID)
        #expect(topology.kind == .singleUnit)
        #expect(topology.logicalSize == MiragePixelSize(width: 1920, height: 1080))
        #expect(topology.units.count == 1)
        #expect(topology.units[0].id == .primary)
        #expect(topology.units[0].sourceRect == MiragePixelRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(topology.units[0].presentationRect == MiragePixelRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(topology.units[0].codec == .hevc)
        #expect(topology.units[0].dependencyScope == .independent)
        #expect(topology.representsSingleUnitFullFrame)
    }

    @Test("Topology value types normalize stable geometry and identifiers")
    func topologyValueTypesNormalizeStableGeometryAndIdentifiers() {
        #expect(MirageMediaUnitID(rawValue: "  ").rawValue == "primary")
        #expect(MirageMediaUnitID(rawValue: " region-a ").rawValue == "region-a")
        #expect(MiragePixelSize(width: -1, height: 10).width == 0)
        #expect(MiragePixelSize(width: 10, height: 0).isEmpty)
        #expect(MiragePixelRect(x: -2, y: -4, width: -8, height: 12) == MiragePixelRect(x: 0, y: 0, width: 0, height: 12))

        let unit = MirageMediaUnitDescriptor(
            id: MirageMediaUnitID(rawValue: "dependent"),
            sourceRect: MiragePixelRect(x: 0, y: 0, width: 640, height: 480),
            presentationRect: MiragePixelRect(x: 640, y: 0, width: 640, height: 480),
            codec: .h264,
            dependencyScope: .dependent
        )
        let topology = MirageMediaTopology(
            kind: .multiUnit,
            logicalSize: MiragePixelSize(width: 1280, height: 480),
            units: [unit]
        )

        #expect(!topology.representsSingleUnitFullFrame)
        #expect(topology.units[0].presentationRect.size == MiragePixelSize(width: 640, height: 480))
    }

    @Test("Topology payloads keep stable Codable names")
    func topologyPayloadsKeepStableCodableNames() throws {
        let topology = MirageMediaTopology.singleUnit(
            id: MirageMediaTopologyID(
                rawValue: try #require(UUID(uuidString: "641524D0-F1C0-4D52-9B90-C8837C9F4780"))
            ),
            logicalSize: MiragePixelSize(width: 2560, height: 1440),
            codec: .proRes4444
        )

        let encoded = try JSONEncoder().encode(topology)
        let decoded = try JSONDecoder().decode(MirageMediaTopology.self, from: encoded)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(decoded == topology)
        #expect(json.contains("\"singleUnit\""))
        #expect(json.contains("\"primary\""))
        #expect(json.contains("\"ap4h\""))
        #expect(MirageMediaTopologyKind.allCases == [.singleUnit, .atlas, .multiUnit, .mosaic, .replay])
    }

    @Test("Fixed-grid Mosaic tile plan maps to topology-aware codec units")
    func fixedGridMosaicTilePlanMapsToTopologyAwareCodecUnits() {
        let plan = MirageMosaicTilePlan.fixedGrid(
            logicalSize: MiragePixelSize(width: 6000, height: 3376),
            columns: 3,
            rows: 3,
            codec: .hevc
        )

        #expect(plan.kind == .fixedGrid)
        #expect(plan.tiles.count == 9)
        #expect(plan.codecUnits.count == 9)
        #expect(plan.tiles[0].sourceRect == MiragePixelRect(x: 0, y: 0, width: 2000, height: 1125))
        #expect(plan.tiles[8].sourceRect == MiragePixelRect(x: 4000, y: 2250, width: 2000, height: 1126))
        #expect(plan.tiles.allSatisfy { $0.semanticClass == .gridFallback })

        let topology = plan.mediaTopology
        #expect(topology.id == plan.id)
        #expect(topology.kind == .mosaic)
        #expect(topology.logicalSize == MiragePixelSize(width: 6000, height: 3376))
        #expect(topology.units.count == plan.codecUnits.count)
        #expect(topology.units[4].id == MirageMediaUnitID(rawValue: "grid-4"))
        #expect(!topology.representsSingleUnitFullFrame)
    }

    @Test("Semantic Mosaic descriptors keep group and text metadata")
    func semanticMosaicDescriptorsKeepGroupAndTextMetadata() {
        let scrollTileID = MirageMosaicTileID(rawValue: "focused-scroll")
        let groupID = MirageMosaicPresentationGroupID(rawValue: "active-scroll-group")
        let tile = MirageMosaicTileDescriptor(
            id: scrollTileID,
            sourceRect: MiragePixelRect(x: 120, y: 96, width: 2400, height: 1600),
            presentationRect: MiragePixelRect(x: 120, y: 96, width: 2400, height: 1600),
            semanticClass: .scrollView,
            priority: .focusedContent,
            codecStrategy: .verticalColumns,
            presentationGroupID: groupID,
            commitPolicy: .atomic
        )

        #expect(tile.textSensitive)
        #expect(tile.presentationGroupID == groupID)
        #expect(tile.commitPolicy == .atomic)
        #expect(tile.codecStrategy == .verticalColumns)
    }
}
