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
    @Test("Target FPS normalization uses 60/120 buckets")
    func normalizedTargetFPS() {
        #expect(MirageRenderModePolicy.normalizedTargetFPS(1) == 60)
        #expect(MirageRenderModePolicy.normalizedTargetFPS(60) == 60)
        #expect(MirageRenderModePolicy.normalizedTargetFPS(90) == 60)
        #expect(MirageRenderModePolicy.normalizedTargetFPS(120) == 120)
        #expect(MirageRenderModePolicy.normalizedTargetFPS(144) == 120)
    }

    @Test("Decode-health thresholds stay stable")
    func decodeHealthThresholds() {
        #expect(MirageRenderModePolicy.healthyDecodeRatio == 0.95)
        #expect(MirageRenderModePolicy.stressedDecodeRatio == 0.80)
    }

    @Test("Stress buffer depth stays bounded")
    func stressBufferDepth() {
        #expect(MirageRenderModePolicy.maxStressBufferDepth == 3)
    }
}
