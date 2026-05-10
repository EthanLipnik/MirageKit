//
//  MirageRenderModePolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Shared render telemetry thresholds and frame pacing policy constants.
//

import Foundation
import MirageKit

enum MirageRenderModePolicy {
    static let healthyDecodeRatio = 0.95
    static let stressedDecodeRatio = 0.80
    static let maximumSmoothestPlayoutDelayFrames = 1

    static func normalizedTargetFPS(_ fps: Int) -> Int {
        max(1, min(120, fps))
    }

    static func playoutDelayFrames(for latencyMode: MirageStreamLatencyMode) -> Int {
        switch latencyMode {
        case .lowestLatency:
            0
        case .smoothest:
            1
        }
    }
}
