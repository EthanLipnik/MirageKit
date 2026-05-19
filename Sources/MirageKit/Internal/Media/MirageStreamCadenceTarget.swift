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
    package static let maximumPlayoutDelayFrames = 2

    /// Capture or encoded-source cadence after clamping to Mirage's supported FPS range.
    package let sourceFPS: Int

    /// Display refresh cadence used for presentation pacing after clamping.
    package let displayFPS: Int

    /// Latency policy that determines how many frames may be buffered for playout.
    package let latencyMode: MirageStreamLatencyMode

    /// Number of source frames the presenter may intentionally buffer for playout.
    package let playoutDelayFrames: Int

    /// Creates a cadence target, clamping source and display rates into Mirage's supported range.
    package init(
        sourceFPS: Int,
        displayFPS: Int? = nil,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        playoutDelayFrames: Int? = nil
    ) {
        let resolvedSourceFPS = Self.normalizedFPS(sourceFPS)
        self.sourceFPS = resolvedSourceFPS
        self.displayFPS = Self.normalizedFPS(displayFPS ?? resolvedSourceFPS)
        self.latencyMode = latencyMode
        self.playoutDelayFrames = Self.clampedPlayoutDelayFrames(
            playoutDelayFrames ?? Self.defaultPlayoutDelayFrames(for: latencyMode)
        )
    }

    /// Per-source-frame time budget in milliseconds.
    package var sourceFrameBudgetMs: Double {
        1_000.0 / Double(max(1, sourceFPS))
    }

    /// Number of frames the presenter may intentionally buffer for the selected latency mode.
    package static func defaultPlayoutDelayFrames(for latencyMode: MirageStreamLatencyMode) -> Int {
        switch latencyMode {
        case .lowestLatency:
            0
        case .smoothest:
            1
        }
    }

    /// Clamps a requested playout delay into the supported live-stream range.
    package static func clampedPlayoutDelayFrames(_ frames: Int) -> Int {
        max(0, min(maximumPlayoutDelayFrames, frames))
    }

    /// Clamps an FPS value into Mirage's supported cadence range.
    package static func normalizedFPS(_ fps: Int) -> Int {
        max(1, min(240, fps))
    }
}
