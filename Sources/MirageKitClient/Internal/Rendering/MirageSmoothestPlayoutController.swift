//
//  MirageSmoothestPlayoutController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/15/26.
//

import Foundation

enum MiragePresentationDecisionMode: String, Equatable, Sendable {
    case lowestLatency
    case cushioned
    case liveEdge
}

struct MiragePresentationDecision: Equatable, Sendable {
    let playoutDelayFrames: Int
    let displaysImmediately: Bool
    let queueTargetDepth: Int
    let mode: MiragePresentationDecisionMode
}

/// Elastic smoothest-mode state that adds timed playout only after local jitter.
struct MirageSmoothestPlayoutController: Equatable, Sendable {
    static let cushionHoldDuration: CFTimeInterval = 0.750
    static let healthSampleFreshness: CFTimeInterval = 1.250
    static let liveEdgeHealthyWindowRequirement = 2

    private var lastJitterTime: CFTimeInterval?
    private var lastHealthSampleTime: CFTimeInterval?
    private var consecutiveLiveEdgeHealthySamples = 0

    mutating func reset() {
        lastJitterTime = nil
        lastHealthSampleTime = nil
        consecutiveLiveEdgeHealthySamples = 0
    }

    mutating func noteJitter(at time: CFTimeInterval) {
        lastJitterTime = time
    }

    mutating func recordHealthSample(healthyForLiveEdge: Bool, at time: CFTimeInterval) {
        lastHealthSampleTime = time
        if healthyForLiveEdge {
            consecutiveLiveEdgeHealthySamples += 1
        } else {
            consecutiveLiveEdgeHealthySamples = 0
        }
    }

    mutating func presentationDecision(
        policy: MiragePresentationLatencyPolicy,
        now: CFTimeInterval
    ) -> MiragePresentationDecision {
        switch policy.latencyMode {
        case .lowestLatency:
            return MiragePresentationDecision(
                playoutDelayFrames: 0,
                displaysImmediately: true,
                queueTargetDepth: policy.maximumQueueDepth,
                mode: .lowestLatency
            )
        case .smoothest:
            let useCushion = shouldUseCushion(
                now: now
            )
            if !useCushion {
                lastJitterTime = nil
            }
            return MiragePresentationDecision(
                playoutDelayFrames: useCushion ? policy.targetPlayoutDelayFrames : 0,
                displaysImmediately: !useCushion,
                queueTargetDepth: useCushion ? policy.maximumQueueDepth : 1,
                mode: useCushion ? .cushioned : .liveEdge
            )
        }
    }

    private func shouldUseCushion(now: CFTimeInterval) -> Bool {
        guard hasFreshLiveEdgeHealth(now: now) else { return true }
        guard let lastJitterTime else { return false }
        return now - lastJitterTime <= Self.cushionHoldDuration
    }

    private func hasFreshLiveEdgeHealth(now: CFTimeInterval) -> Bool {
        guard consecutiveLiveEdgeHealthySamples >= Self.liveEdgeHealthyWindowRequirement,
              let lastHealthSampleTime else {
            return false
        }
        return now - lastHealthSampleTime <= Self.healthSampleFreshness
    }
}
