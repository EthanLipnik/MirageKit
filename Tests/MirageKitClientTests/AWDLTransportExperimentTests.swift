//
//  AWDLTransportExperimentTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  AWDL experiment transport helper behavior coverage.
//

@testable import MirageKitClient
import MirageKit
import Foundation
import Testing

#if os(macOS)
@Suite("AWDL Transport Experiment")
struct AWDLTransportExperimentTests {
    @Test("Keyframe request cooldown gate blocks requests inside cooldown window")
    func keyframeCooldownGate() {
        let now: CFAbsoluteTime = 1_000
        #expect(
            MirageClientService.shouldSendKeyframeRequest(
                lastRequestTime: nil,
                now: now,
                cooldown: 0.25
            )
        )
        #expect(
            !MirageClientService.shouldSendKeyframeRequest(
                lastRequestTime: now - 0.1,
                now: now,
                cooldown: 0.25
            )
        )
        #expect(
            MirageClientService.shouldSendKeyframeRequest(
                lastRequestTime: now - 0.3,
                now: now,
                cooldown: 0.25
            )
        )
    }

    @Test("Adaptive jitter state caps at 8ms under stress and drains to 0ms after stability")
    func adaptiveJitterStateBoundsAndRecovery() {
        var state = StreamController.AdaptiveJitterState(holdMs: 0, stressStreak: 0, stableStreak: 0)

        for _ in 0 ..< 12 {
            state = StreamController.nextAdaptiveJitterState(
                current: state,
                receivedFPS: 35,
                targetFPS: 60
            )
        }
        #expect(state.holdMs == StreamController.adaptiveJitterHoldMaxMs)

        for _ in 0 ..< 40 {
            state = StreamController.nextAdaptiveJitterState(
                current: state,
                receivedFPS: 60,
                targetFPS: 60
            )
        }
        #expect(state.holdMs == 0)
        #expect(state.stressStreak == 0)
    }
}
#endif
