//
//  RenderModePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for latency-mode render policy decisions.
//

@testable import MirageKitClient
import MirageKit
import Testing

@Suite("Render Mode Policy")
struct RenderModePolicyTests {
    @Test("Lowest latency keeps depth 1 with off-cycle wake")
    func lowestLatencyDecision() {
        let decision = MirageRenderModePolicy.decision(
            latencyMode: .lowestLatency,
            typingBurstActive: false,
            targetFPS: 60
        )

        #expect(decision.profile == .lowestLatency)
        #expect(decision.presentationKeepDepth == 1)
        #expect(decision.preferLatest)
        #expect(!decision.allowCadenceRepeat)
        #expect(decision.allowOffCycleWake)
    }

    @Test("Auto typing burst switches to latency-first profile")
    func autoTypingBurstDecision() {
        let decision = MirageRenderModePolicy.decision(
            latencyMode: .auto,
            typingBurstActive: true,
            targetFPS: 60
        )

        #expect(decision.profile == .autoTyping)
        #expect(decision.presentationKeepDepth == 1)
        #expect(decision.preferLatest)
        #expect(!decision.allowCadenceRepeat)
        #expect(decision.allowOffCycleWake)
    }

    @Test("Auto idle uses smooth cadence behavior")
    func autoIdleDecision() {
        let decision = MirageRenderModePolicy.decision(
            latencyMode: .auto,
            typingBurstActive: false,
            targetFPS: 60
        )

        #expect(decision.profile == .autoSmooth)
        #expect(decision.presentationKeepDepth == 2)
        #expect(!decision.preferLatest)
        #expect(decision.allowCadenceRepeat)
        #expect(!decision.allowOffCycleWake)
    }

    @Test("Smoothest repeats cadence and scales keep depth by target refresh")
    func smoothestCadenceDecision() {
        let decision60 = MirageRenderModePolicy.decision(
            latencyMode: .smoothest,
            typingBurstActive: false,
            targetFPS: 60
        )
        let decision120 = MirageRenderModePolicy.decision(
            latencyMode: .smoothest,
            typingBurstActive: false,
            targetFPS: 120
        )

        #expect(decision60.profile == .smoothest)
        #expect(decision60.presentationKeepDepth == 2)
        #expect(decision60.allowCadenceRepeat)

        #expect(decision120.profile == .smoothest)
        #expect(decision120.presentationKeepDepth == 3)
        #expect(decision120.allowCadenceRepeat)
    }
}
