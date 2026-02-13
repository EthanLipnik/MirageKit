//
//  RenderSchedulerFrameRateLockTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Coverage for iOS render scheduler frame-rate lock normalization.
//

@testable import MirageKitClient
import Testing

@Suite("Render Scheduler Frame Rate Lock")
struct RenderSchedulerFrameRateLockTests {
    @Test("Normalization clamps refresh to 60/120 buckets")
    @MainActor
    func normalizedRefreshBuckets() {
        #expect(MirageRenderScheduler.normalizedTargetFPS(1) == 60)
        #expect(MirageRenderScheduler.normalizedTargetFPS(59) == 60)
        #expect(MirageRenderScheduler.normalizedTargetFPS(60) == 60)
        #expect(MirageRenderScheduler.normalizedTargetFPS(61) == 60)
        #expect(MirageRenderScheduler.normalizedTargetFPS(119) == 60)
        #expect(MirageRenderScheduler.normalizedTargetFPS(120) == 120)
        #expect(MirageRenderScheduler.normalizedTargetFPS(240) == 120)
    }
}
