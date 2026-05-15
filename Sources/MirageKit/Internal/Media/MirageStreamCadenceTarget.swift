//
//  MirageStreamCadenceTarget.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/6/26.
//
//  Internal stream cadence and frame-budget model.
//

import Foundation

/// Normalized frame-cadence model used to derive timing budgets for a stream.
package struct MirageStreamCadenceTarget: Sendable, Equatable {
    /// Capture or encoded-source cadence after clamping to Mirage's supported FPS range.
    package let sourceFPS: Int

    /// Display refresh cadence used for presentation pacing after clamping.
    package let displayFPS: Int

    /// Latency policy that determines how many frames may be buffered for playout.
    package let latencyMode: MirageStreamLatencyMode

    /// Creates a cadence target, clamping source and display rates into Mirage's supported range.
    package init(
        sourceFPS: Int,
        displayFPS: Int? = nil,
        latencyMode: MirageStreamLatencyMode = .lowestLatency
    ) {
        let resolvedSourceFPS = Self.normalizedFPS(sourceFPS)
        self.sourceFPS = resolvedSourceFPS
        self.displayFPS = Self.normalizedFPS(displayFPS ?? resolvedSourceFPS)
        self.latencyMode = latencyMode
    }

    /// Per-source-frame time budget in milliseconds.
    package var sourceFrameBudgetMs: Double {
        1_000.0 / Double(max(1, sourceFPS))
    }

    /// Number of frames the presenter may intentionally buffer for the selected latency mode.
    package var playoutDelayFrames: Int {
        Self.playoutDelayFrames(for: latencyMode)
    }

    /// Number of frames the presenter may intentionally buffer for a latency mode.
    package static func playoutDelayFrames(for latencyMode: MirageStreamLatencyMode) -> Int {
        switch latencyMode {
        case .lowestLatency:
            0
        case .smoothest:
            1
        }
    }

    /// Clamps an FPS value into Mirage's supported cadence range.
    package static func normalizedFPS(_ fps: Int) -> Int {
        max(1, min(240, fps))
    }
}
