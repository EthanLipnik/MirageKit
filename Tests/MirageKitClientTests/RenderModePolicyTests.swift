//
//  RenderModePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for decode-health-driven render policy decisions.
//

@testable import MirageKitClient
import MirageKit
import Testing

@Suite("Render Mode Policy")
struct RenderModePolicyTests {
    @Test("Lowest latency always presents latest frames")
    func lowestLatencyDecision() {
        let decision = MirageRenderModePolicy.decision(
            latencyMode: .lowestLatency,
            typingBurstActive: false,
            decodeHealthy: false,
            targetFPS: 60
        )

        #expect(decision.profile == .lowestLatency)
        #expect(decision.presentationPolicy == .latest)
        #expect(!decision.decodeHealthy)
        #expect(decision.allowOffCycleWake)
    }

    @Test("Auto typing burst keeps low-latency path even under decode stress")
    func autoTypingBurstDecision() {
        let decision = MirageRenderModePolicy.decision(
            latencyMode: .auto,
            typingBurstActive: true,
            decodeHealthy: false,
            targetFPS: 60
        )

        #expect(decision.profile == .autoTyping)
        #expect(decision.presentationPolicy == .latest)
        #expect(!decision.decodeHealthy)
        #expect(decision.allowOffCycleWake)
    }

    @Test("Auto non-typing uses buffered smooth presentation")
    func autoHealthyDecision() {
        let decision = MirageRenderModePolicy.decision(
            latencyMode: .auto,
            typingBurstActive: false,
            decodeHealthy: true,
            targetFPS: 60
        )

        #expect(decision.profile == .autoSmooth)
        #expect(decision.presentationPolicy == .buffered(maxDepth: 3))
        #expect(decision.decodeHealthy)
        #expect(!decision.allowOffCycleWake)
    }

    @Test("Auto decode stress stays in bounded buffering mode")
    func autoStressDecision() {
        let decision = MirageRenderModePolicy.decision(
            latencyMode: .auto,
            typingBurstActive: false,
            decodeHealthy: false,
            targetFPS: 120
        )

        #expect(decision.profile == .autoSmooth)
        #expect(decision.presentationPolicy == .buffered(maxDepth: 3))
        #expect(!decision.decodeHealthy)
        #expect(!decision.allowOffCycleWake)
    }

    @Test("Smoothest always uses buffered presentation")
    func smoothestDecision() {
        let healthy = MirageRenderModePolicy.decision(
            latencyMode: .smoothest,
            typingBurstActive: false,
            decodeHealthy: true,
            targetFPS: 60
        )
        let stressed = MirageRenderModePolicy.decision(
            latencyMode: .smoothest,
            typingBurstActive: false,
            decodeHealthy: false,
            targetFPS: 60
        )

        #expect(healthy.profile == .smoothest)
        #expect(healthy.presentationPolicy == .buffered(maxDepth: 3))
        #expect(!healthy.allowOffCycleWake)

        #expect(stressed.profile == .smoothest)
        #expect(stressed.presentationPolicy == .buffered(maxDepth: 3))
        #expect(!stressed.allowOffCycleWake)
    }
}
