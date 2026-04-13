//
//  RenderModePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for shared render policy constants.
//

@testable import MirageKitClient
import Testing

@Suite("Render Mode Policy")
struct RenderModePolicyTests {
    @Test("Target FPS normalization clamps to the supported range")
    func normalizedTargetFPS() {
        #expect(MirageRenderModePolicy.normalizedTargetFPS(1) == 1)
        #expect(MirageRenderModePolicy.normalizedTargetFPS(30) == 30)
        #expect(MirageRenderModePolicy.normalizedTargetFPS(60) == 60)
        #expect(MirageRenderModePolicy.normalizedTargetFPS(90) == 90)
        #expect(MirageRenderModePolicy.normalizedTargetFPS(120) == 120)
        #expect(MirageRenderModePolicy.normalizedTargetFPS(144) == 120)
    }

    @Test("Decode-health thresholds stay stable")
    func decodeHealthThresholds() {
        #expect(MirageRenderModePolicy.healthyDecodeRatio == 0.95)
        #expect(MirageRenderModePolicy.stressedDecodeRatio == 0.80)
    }
}
