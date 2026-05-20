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
    let hasRecentInteraction: Bool

    init(
        latencyMode: MirageStreamLatencyMode,
        sourceFPS: Int,
        displayFPS: Int,
        hasRecentInteraction: Bool = false
    ) {
        self.latencyMode = latencyMode
        self.sourceFPS = MirageRenderModePolicy.normalizedTargetFPS(sourceFPS)
        self.displayFPS = MirageRenderModePolicy.normalizedTargetFPS(displayFPS)
        self.hasRecentInteraction = hasRecentInteraction
    }

    var targetPlayoutDelayFrames: Int {
        switch latencyMode {
        case .lowestLatency:
            0
        case .smoothest:
            MirageStreamCadenceTarget.defaultPlayoutDelayFrames(for: .smoothest)
        }
    }

    var maximumQueueDepth: Int {
        switch latencyMode {
        case .lowestLatency:
            return 1
        case .smoothest:
            return max(1, Int((hardResetDebtMs / displayFrameIntervalMs).rounded(.down)) + 1)
        }
    }

    var maximumQueueAgeMs: Double {
        switch latencyMode {
        case .lowestLatency:
            return sourceFrameIntervalMs
        case .smoothest:
            return hardResetDebtMs
        }
    }

    var smoothestDisplayDebtCapMs: Double {
        guard latencyMode == .smoothest else {
            return sourceFrameIntervalMs
        }
        return hasRecentInteraction ? 100 : 150
    }

    var hardResetDebtMs: Double {
        switch latencyMode {
        case .lowestLatency:
            return sourceFrameIntervalMs
        case .smoothest:
            return 300
        }
    }

    var displayFrameIntervalMs: Double {
        1000 / Double(max(1, displayFPS))
    }

    private var sourceFrameIntervalMs: Double {
        1000 / Double(max(1, sourceFPS))
    }
}
