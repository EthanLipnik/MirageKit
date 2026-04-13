//
//  MirageDisplaySizePresetTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import CoreGraphics
import MirageKit
import Testing

@Suite("Mirage Display Size Preset")
struct MirageDisplaySizePresetTests {
    @Test("Medium preset uses 16 by 10 backing resolution")
    func mediumPresetUsesSixteenByTenResolution() {
        #expect(MirageDisplaySizePreset.medium.pixelResolution == CGSize(width: 3840, height: 2400))
        #expect(MirageDisplaySizePreset.medium.logicalResolution == CGSize(width: 1920, height: 1200))
    }

    @Test("Preset aspect ratios match intended client classes")
    func presetAspectRatiosMatchIntendedClientClasses() {
        #expect(abs(MirageDisplaySizePreset.standard.contentAspectRatio - (4.0 / 3.0)) < 0.0001)
        #expect(abs(MirageDisplaySizePreset.medium.contentAspectRatio - (16.0 / 10.0)) < 0.0001)
        #expect(abs(MirageDisplaySizePreset.large.contentAspectRatio - (16.0 / 9.0)) < 0.0001)
    }
}
