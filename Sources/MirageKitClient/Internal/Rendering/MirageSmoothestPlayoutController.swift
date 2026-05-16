//
//  MirageSmoothestPlayoutController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/15/26.
//

import Foundation

enum MiragePresentationDecisionMode: String, Equatable, Sendable {
    case lowestLatency
    case liveEdge
    case softCushion
    case hardCushion
}

struct MiragePresentationDecision: Equatable, Sendable {
    let playoutDelayFrames: Int
    let displaysImmediately: Bool
    let queueTargetDepth: Int
    let mode: MiragePresentationDecisionMode
}

/// Elastic smoothest-mode state that adds timed playout only after local jitter.
struct MirageSmoothestPlayoutController: Equatable, Sendable {
    enum JitterSeverity: Equatable, Sendable {
        case soft
        case hard
    }

    static let softCushionHoldDuration: CFTimeInterval = 0.220
    static let hardCushionHoldDuration: CFTimeInterval = 0.750
    static let healthSampleFreshness: CFTimeInterval = 1.250
    static let startupLiveEdgeHealthyWindowRequirement = 1
    static let postHardCushionLiveEdgeHealthyWindowRequirement = 2

    private var lastSoftJitterTime: CFTimeInterval?
    private var lastHardJitterTime: CFTimeInterval?
    private var lastHealthSampleTime: CFTimeInterval?
    private var consecutiveLiveEdgeHealthySamples = 0
    private var recentSoftJitterCount = 0
    private var requiresPostHardHealthyHysteresis = false

    mutating func reset() {
        lastSoftJitterTime = nil
        lastHardJitterTime = nil
        lastHealthSampleTime = nil
        consecutiveLiveEdgeHealthySamples = 0
        recentSoftJitterCount = 0
        requiresPostHardHealthyHysteresis = false
    }

    mutating func noteJitter(
        at time: CFTimeInterval,
        severity: JitterSeverity = .soft
    ) {
        switch severity {
        case .soft:
            if let lastSoftJitterTime,
               time - lastSoftJitterTime <= Self.softCushionHoldDuration {
                recentSoftJitterCount += 1
            } else {
                recentSoftJitterCount = 1
            }
            lastSoftJitterTime = time
            if recentSoftJitterCount >= 2 {
                noteHardJitter(at: time)
            }
        case .hard:
            noteHardJitter(at: time)
        }
    }

    mutating func recordHealthSample(
        healthyForLiveEdge: Bool,
        requiresHardCushion: Bool = false,
        at time: CFTimeInterval
    ) {
        lastHealthSampleTime = time
        if requiresHardCushion {
            noteHardJitter(at: time)
        }
        if healthyForLiveEdge, !requiresHardCushion {
            consecutiveLiveEdgeHealthySamples += 1
        } else {
            consecutiveLiveEdgeHealthySamples = 0
            if !requiresHardCushion {
                noteJitter(at: time, severity: .soft)
            }
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
            let mode = smoothestMode(now: now)
            if mode == .liveEdge {
                lastSoftJitterTime = nil
                lastHardJitterTime = nil
                recentSoftJitterCount = 0
                requiresPostHardHealthyHysteresis = false
            }
            return MiragePresentationDecision(
                playoutDelayFrames: 0,
                displaysImmediately: true,
                queueTargetDepth: queueTargetDepth(for: mode, policy: policy),
                mode: mode
            )
        }
    }

    private mutating func noteHardJitter(at time: CFTimeInterval) {
        lastHardJitterTime = time
        requiresPostHardHealthyHysteresis = true
        consecutiveLiveEdgeHealthySamples = 0
    }

    private func smoothestMode(now: CFTimeInterval) -> MiragePresentationDecisionMode {
        if let lastHardJitterTime,
           now - lastHardJitterTime <= Self.hardCushionHoldDuration {
            return .hardCushion
        }
        guard hasFreshLiveEdgeHealth(now: now) else {
            return .softCushion
        }
        if let lastSoftJitterTime,
           now - lastSoftJitterTime <= Self.softCushionHoldDuration {
            return .softCushion
        }
        return .liveEdge
    }

    private func queueTargetDepth(
        for mode: MiragePresentationDecisionMode,
        policy: MiragePresentationLatencyPolicy
    ) -> Int {
        switch mode {
        case .lowestLatency, .liveEdge:
            return 1
        case .softCushion:
            return policy.softCushionQueueDepth
        case .hardCushion:
            return policy.maximumQueueDepth
        }
    }

    private func hasFreshLiveEdgeHealth(now: CFTimeInterval) -> Bool {
        let requiredSamples = requiresPostHardHealthyHysteresis
            ? Self.postHardCushionLiveEdgeHealthyWindowRequirement
            : Self.startupLiveEdgeHealthyWindowRequirement
        guard consecutiveLiveEdgeHealthySamples >= requiredSamples,
              let lastHealthSampleTime else {
            return false
        }
        return now - lastHealthSampleTime <= Self.healthSampleFreshness
    }
}
