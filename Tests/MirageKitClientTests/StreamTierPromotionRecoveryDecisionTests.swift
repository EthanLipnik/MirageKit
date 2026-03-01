//
//  StreamTierPromotionRecoveryDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//
//  Decision coverage for passive->active tier-promotion recovery behavior.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Tier Promotion Recovery Decision")
struct StreamTierPromotionRecoveryDecisionTests {
    @Test("Missing presented frame forces immediate keyframe recovery")
    func missingPresentedFrameForcesImmediateKeyframeRecovery() {
        let decision = streamTierPromotionRecoveryDecision(
            hasPresentedFirstFrame: false,
            isAwaitingKeyframe: false,
            hasKeyframeAnchor: true
        )

        #expect(decision == .forceImmediateKeyframe(.noPresentedFrame))
    }

    @Test("Awaiting keyframe forces immediate keyframe recovery")
    func awaitingKeyframeForcesImmediateKeyframeRecovery() {
        let decision = streamTierPromotionRecoveryDecision(
            hasPresentedFirstFrame: true,
            isAwaitingKeyframe: true,
            hasKeyframeAnchor: true
        )

        #expect(decision == .forceImmediateKeyframe(.awaitingKeyframe))
    }

    @Test("Missing keyframe anchor forces immediate keyframe recovery")
    func missingKeyframeAnchorForcesImmediateKeyframeRecovery() {
        let decision = streamTierPromotionRecoveryDecision(
            hasPresentedFirstFrame: true,
            isAwaitingKeyframe: false,
            hasKeyframeAnchor: false
        )

        #expect(decision == .forceImmediateKeyframe(.noKeyframeAnchor))
    }

    @Test("Healthy decode context keeps P-frame-first promotion")
    func healthyContextKeepsPFrameFirstPromotion() {
        let decision = streamTierPromotionRecoveryDecision(
            hasPresentedFirstFrame: true,
            isAwaitingKeyframe: false,
            hasKeyframeAnchor: true
        )

        #expect(decision == .pFrameFirst)
    }
}
#endif
