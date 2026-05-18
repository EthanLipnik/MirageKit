//
//  HostCaptureQueueDepthPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/18/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Host Capture Queue Depth Policy")
struct HostCaptureQueueDepthPolicyTests {
    @Test("Freshest-frame lowest-latency uses minimum practical SCK queue depth")
    func freshestFrameLowestLatencyUsesMinimumSCKQueueDepth() {
        let depth = WindowCaptureEngine.resolveSCKQueueDepth(
            width: 1920,
            height: 1080,
            frameRate: 60,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            overrideDepth: nil
        )

        #expect(depth == 3)
    }

    @Test("Freshest-frame SCK queue depth respects explicit override")
    func freshestFrameSCKQueueDepthRespectsOverride() {
        let depth = WindowCaptureEngine.resolveSCKQueueDepth(
            width: 1920,
            height: 1080,
            frameRate: 60,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            overrideDepth: 8
        )

        #expect(depth == 8)
    }

    @Test("Stability lowest-latency keeps existing SCK queue default")
    func stabilityLowestLatencyKeepsExistingSCKQueueDefault() {
        let depth = WindowCaptureEngine.resolveSCKQueueDepth(
            width: 1920,
            height: 1080,
            frameRate: 60,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .stability,
            overrideDepth: nil
        )

        #expect(depth == 6)
    }
}
#endif
