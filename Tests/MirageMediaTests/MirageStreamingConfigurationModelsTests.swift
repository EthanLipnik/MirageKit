//
//  MirageStreamingConfigurationModelsTests.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import Foundation
import MirageMedia
import Testing

@Suite("MirageMedia Streaming Configuration Models")
struct MirageStreamingConfigurationModelsTests {
    @Test("Host buffering policy keeps stable wire names")
    func hostBufferingPolicyKeepsStableWireNames() throws {
        #expect(MirageMedia.MirageHostBufferingPolicy.stability.rawValue == "stability")
        #expect(MirageMedia.MirageHostBufferingPolicy.freshestFrame.rawValue == "freshestFrame")

        let encoded = try JSONEncoder().encode(MirageMedia.MirageHostBufferingPolicy.freshestFrame)
        let decoded = try JSONDecoder().decode(MirageMedia.MirageHostBufferingPolicy.self, from: encoded)

        #expect(decoded == .freshestFrame)
    }

    @Test("Desktop stream modes keep raw names and labels")
    func desktopStreamModesKeepRawNamesAndLabels() {
        #expect(MirageMedia.MirageDesktopStreamMode.allCases.map(\.rawValue) == ["unified", "secondary"])
        #expect(MirageMedia.MirageDesktopStreamMode.unified.displayName == "Unified")
        #expect(MirageMedia.MirageDesktopStreamMode.secondary.displayName == "Secondary Display")
    }

    @Test("Display size presets keep geometry and labels")
    func displaySizePresetsKeepGeometryAndLabels() {
        #expect(MirageMedia.MirageDisplaySizePreset.defaultsKey == "streamSizePreset")
        #expect(MirageMedia.MirageDisplaySizePreset.standard.pixelResolution == CGSize(width: 2752, height: 2064))
        #expect(MirageMedia.MirageDisplaySizePreset.medium.logicalResolution == CGSize(width: 1920, height: 1200))
        #expect(abs(MirageMedia.MirageDisplaySizePreset.large.contentAspectRatio - (5120.0 / 2880.0)) < 0.0001)
        #expect(MirageMedia.MirageDisplaySizePreset.large.displayName == "Large")
        #expect(MirageMedia.MirageDisplaySizePreset.standard.subtitle == "Best for iPad")
        #expect(MirageMedia.MirageDisplaySizePreset.medium.footerDescription == "Scale app streams for a MacBook-sized display.")
    }
}
