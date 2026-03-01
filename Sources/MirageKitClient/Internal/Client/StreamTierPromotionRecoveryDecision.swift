//
//  StreamTierPromotionRecoveryDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//

import Foundation

enum StreamTierPromotionRecoveryReason: Equatable {
    case noPresentedFrame
    case awaitingKeyframe
    case noKeyframeAnchor
}

enum StreamTierPromotionRecoveryDecision: Equatable {
    case forceImmediateKeyframe(StreamTierPromotionRecoveryReason)
    case pFrameFirst
}

func streamTierPromotionRecoveryDecision(
    hasPresentedFirstFrame: Bool,
    isAwaitingKeyframe: Bool,
    hasKeyframeAnchor: Bool
) -> StreamTierPromotionRecoveryDecision {
    if !hasPresentedFirstFrame {
        return .forceImmediateKeyframe(.noPresentedFrame)
    }

    if isAwaitingKeyframe {
        return .forceImmediateKeyframe(.awaitingKeyframe)
    }

    if !hasKeyframeAnchor {
        return .forceImmediateKeyframe(.noKeyframeAnchor)
    }

    return .pFrameFirst
}
