//
//  MiragePresentationLatencyPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

import Foundation
import MirageKit

/// Local client presentation bounds for a stream latency mode.
///
/// This policy only controls decoded-frame playout on the client. It must not
/// be used to change host capture cadence, virtual display refresh, stream
/// scale, or encoded resolution.
struct MiragePresentationLatencyPolicy: Equatable, Sendable {
    let latencyMode: MirageStreamLatencyMode
    let sourceFPS: Int
    let displayFPS: Int
    let transportPathKind: MirageNetworkPathKind
    let hasRecentInteraction: Bool
    let lastInteractionAgeSeconds: CFTimeInterval?

    init(
        latencyMode: MirageStreamLatencyMode,
        sourceFPS: Int,
        displayFPS: Int,
        transportPathKind: MirageNetworkPathKind = .unknown,
        hasRecentInteraction: Bool = false,
        lastInteractionAgeSeconds: CFTimeInterval? = nil
    ) {
        self.latencyMode = latencyMode
        self.sourceFPS = MirageRenderModePolicy.normalizedTargetFPS(sourceFPS)
        self.displayFPS = MirageRenderModePolicy.normalizedTargetFPS(displayFPS)
        self.transportPathKind = transportPathKind
        self.hasRecentInteraction = hasRecentInteraction
        self.lastInteractionAgeSeconds = lastInteractionAgeSeconds
    }

    var targetPlayoutDelayFrames: Int {
        switch latencyMode {
        case .lowestLatency:
            0
        case .balanced:
            MirageStreamCadenceTarget.defaultPlayoutDelayFrames(for: .balanced)
        case .smoothest:
            MirageStreamCadenceTarget.defaultPlayoutDelayFrames(for: .smoothest)
        }
    }

    var maximumQueueDepth: Int {
        switch latencyMode {
        case .lowestLatency:
            return 1
        case .balanced:
            return 3
        case .smoothest:
            return min(
                32,
                max(3, Int(((baseTargetPlayoutDelayMs + 150) / displayFrameIntervalMs).rounded(.up)) + 1)
            )
        }
    }

    var maximumQueueAgeMs: Double {
        switch latencyMode {
        case .lowestLatency:
            return sourceFrameIntervalMs
        case .balanced:
            return max(45, displayFrameIntervalMs * 3)
        case .smoothest:
            return max(300, baseTargetPlayoutDelayMs + 250)
        }
    }

    var smoothestDisplayDebtCapMs: Double {
        guard usesBufferedPlayout else {
            return sourceFrameIntervalMs
        }
        if latencyMode == .balanced {
            return max(
                50,
                effectiveTargetPlayoutDelayMs(adaptedDelayMs: baseTargetPlayoutDelayMs) +
                    displayFrameIntervalMs * 2
            )
        }
        return max(100, effectiveTargetPlayoutDelayMs(adaptedDelayMs: baseTargetPlayoutDelayMs) + 50)
    }

    var hardResetDebtMs: Double {
        switch latencyMode {
        case .lowestLatency:
            return sourceFrameIntervalMs
        case .balanced:
            return max(80, displayFrameIntervalMs * 4)
        case .smoothest:
            return max(300, baseTargetPlayoutDelayMs + 250)
        }
    }

    var displayFrameIntervalMs: Double {
        1000 / Double(max(1, displayFPS))
    }

    var sourceFrameIntervalMs: Double {
        1000 / Double(max(1, sourceFPS))
    }

    var baseTargetPlayoutDelayMs: Double {
        switch latencyMode {
        case .lowestLatency:
            return 0
        case .balanced:
            return 0
        case .smoothest:
            switch transportPathKind {
            case .wired, .loopback:
                return 50
            case .wifi:
                return 100
            case .awdl:
                return 160
            case .vpn, .cellular, .other, .unknown:
                return 250
            }
        }
    }

    var minimumTargetPlayoutDelayMs: Double {
        switch latencyMode {
        case .lowestLatency:
            return 0
        case .balanced:
            return 0
        case .smoothest:
            switch transportPathKind {
            case .awdl:
                return 60
            case .wired, .loopback:
                return 30
            case .wifi:
                return 60
            case .vpn, .cellular, .other, .unknown:
                return 100
            }
        }
    }

    var maximumTargetPlayoutDelayMs: Double {
        switch latencyMode {
        case .lowestLatency:
            return 0
        case .balanced:
            return displayFrameIntervalMs
        case .smoothest:
            return max(350, baseTargetPlayoutDelayMs * 2)
        }
    }

    var maximumRetainedPixelBufferBytes: Int {
        switch latencyMode {
        case .lowestLatency:
            return 96 * 1024 * 1024
        case .balanced:
            return 192 * 1024 * 1024
        case .smoothest:
            return 384 * 1024 * 1024
        }
    }

    var inputDelayReductionFraction: Double {
        guard usesBufferedPlayout, hasRecentInteraction else { return 0 }
        let maximumReduction = 0.40
        guard let age = lastInteractionAgeSeconds else { return maximumReduction }

        let rampDuration: CFTimeInterval = 0.250
        let holdDuration: CFTimeInterval = 0.500
        let releaseDuration: CFTimeInterval = 0.750
        if age <= 0 {
            return 0
        }
        if age < rampDuration {
            return maximumReduction * (age / rampDuration)
        }
        if age < rampDuration + holdDuration {
            return maximumReduction
        }
        let releaseAge = age - rampDuration - holdDuration
        guard releaseAge < releaseDuration else { return 0 }
        return maximumReduction * (1 - releaseAge / releaseDuration)
    }

    func effectiveTargetPlayoutDelayMs(adaptedDelayMs: Double) -> Double {
        guard usesBufferedPlayout else { return 0 }
        let clamped = min(max(adaptedDelayMs, minimumTargetPlayoutDelayMs), maximumTargetPlayoutDelayMs)
        let reduced = clamped * (1 - inputDelayReductionFraction)
        return max(minimumTargetPlayoutDelayMs, reduced)
    }

    var usesBufferedPlayout: Bool {
        latencyMode == .balanced || latencyMode == .smoothest
    }

}
