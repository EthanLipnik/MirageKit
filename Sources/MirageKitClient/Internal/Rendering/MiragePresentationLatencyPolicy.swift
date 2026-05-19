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

    init(
        latencyMode: MirageStreamLatencyMode,
        sourceFPS: Int,
        displayFPS: Int
    ) {
        self.latencyMode = latencyMode
        self.sourceFPS = MirageRenderModePolicy.normalizedTargetFPS(sourceFPS)
        self.displayFPS = MirageRenderModePolicy.normalizedTargetFPS(displayFPS)
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
            return highCadence ? 6 : 4
        }
    }

    var maximumQueueAgeMs: Double {
        switch latencyMode {
        case .lowestLatency:
            return frameIntervalMs
        case .smoothest:
            return highCadence ? 75 : 100
        }
    }

    private var highCadence: Bool {
        max(sourceFPS, displayFPS) >= 90
    }

    private var frameIntervalMs: Double {
        1000 / Double(max(1, sourceFPS))
    }
}
