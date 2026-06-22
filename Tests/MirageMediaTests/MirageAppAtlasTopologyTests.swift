//
//  MirageAppAtlasTopologyTests.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import Foundation
import MirageMedia
import Testing

@Suite("MirageMedia App Atlas Topology")
struct MirageAppAtlasTopologyTests {
    @Test("App atlas layout maps each region to an atlas topology unit")
    func appAtlasLayoutMapsEachRegionToAtlasTopologyUnit() throws {
        let topologyID = try MirageMediaTopologyID(
            rawValue: #require(UUID(uuidString: "8D377C35-5E5C-4E2D-A3F2-7244DB6A9F10"))
        )
        let layout = MirageMedia.MirageAppAtlasLayout(
            mediaStreamID: 55,
            layoutEpoch: 7,
            width: 1920,
            height: 2160,
            regions: [
                MirageMedia.MirageAppAtlasRegion(windowID: 31, x: 0, y: 0, width: 1920, height: 1080),
                MirageMedia.MirageAppAtlasRegion(
                    windowID: 32,
                    x: 0,
                    y: 1080,
                    width: 1920,
                    height: 1080,
                    zIndex: 1,
                    isFocused: true
                ),
            ]
        )

        let topology = layout.mediaTopology(id: topologyID, codec: .hevc)

        #expect(layout.canvasSize == CGSize(width: 1920, height: 2160))
        #expect(layout.region(for: 32)?.isFocused == true)
        #expect(topology.id == topologyID)
        #expect(topology.kind == .atlas)
        #expect(topology.logicalSize == MiragePixelSize(width: 1920, height: 2160))
        #expect(topology.units.count == 2)
        #expect(topology.units[0].id == .appAtlasWindow(31))
        #expect(topology.units[0].sourceRect == MiragePixelRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(topology.units[0].presentationRect == MiragePixelRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(topology.units[1].id == .appAtlasWindow(32))
        #expect(topology.units[1].sourceRect == MiragePixelRect(x: 0, y: 1080, width: 1920, height: 1080))
        #expect(topology.units.map(\.codec) == [.hevc, .hevc])
        #expect(!topology.representsSingleUnitFullFrame)
    }

    @Test("App atlas topology can omit hidden regions when requested")
    func appAtlasTopologyCanOmitHiddenRegionsWhenRequested() {
        let layout = MirageMedia.MirageAppAtlasLayout(
            mediaStreamID: 81,
            width: 1024,
            height: 768,
            regions: [
                MirageMedia.MirageAppAtlasRegion(windowID: 71, x: 0, y: 0, width: 512, height: 768),
                MirageMedia.MirageAppAtlasRegion(windowID: 72, x: 512, y: 0, width: 512, height: 768, isVisible: false),
            ]
        )

        let allUnits = layout.mediaTopology(codec: .h264).units
        let visibleUnits = layout.mediaTopology(codec: .h264, includeHiddenRegions: false).units

        #expect(allUnits.map(\.id) == [.appAtlasWindow(71), .appAtlasWindow(72)])
        #expect(visibleUnits.map(\.id) == [.appAtlasWindow(71)])
    }

    @Test("App atlas layout and topology keep Codable contracts")
    func appAtlasLayoutAndTopologyKeepCodableContracts() throws {
        let layout = MirageMedia.MirageAppAtlasLayout(
            mediaStreamID: 91,
            layoutEpoch: 3,
            width: 1280,
            height: 720,
            regions: [
                MirageMedia.MirageAppAtlasRegion(
                    windowID: 501,
                    x: 32,
                    y: 48,
                    width: 640,
                    height: 360,
                    zIndex: 2,
                    isFocused: true,
                    isVisible: true
                ),
            ]
        )
        let topology = layout.mediaTopology(codec: .proRes4444)

        let encodedLayout = try JSONEncoder().encode(layout)
        let decodedLayout = try JSONDecoder().decode(MirageMedia.MirageAppAtlasLayout.self, from: encodedLayout)
        let encodedTopology = try JSONEncoder().encode(topology)
        let decodedTopology = try JSONDecoder().decode(MirageMediaTopology.self, from: encodedTopology)
        let topologyJSON = try #require(String(data: encodedTopology, encoding: .utf8))

        #expect(decodedLayout == layout)
        #expect(decodedTopology == topology)
        #expect(decodedLayout.region(for: 501)?.normalizedRect(in: decodedLayout) == CGRect(
            x: 0.025,
            y: 1.0 / 15.0,
            width: 0.5,
            height: 0.5
        ))
        #expect(topologyJSON.contains("\"atlas\""))
        #expect(topologyJSON.contains("\"appAtlas.window.501\""))
        #expect(topologyJSON.contains("\"ap4h\""))
    }
}
