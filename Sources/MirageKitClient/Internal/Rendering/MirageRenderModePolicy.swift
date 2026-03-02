//
//  MirageRenderModePolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Shared render telemetry thresholds and frame pacing policy constants.
//

import Foundation

enum MirageRenderPresentationPolicy: Sendable, Equatable {
    case latest
    case buffered(maxDepth: Int)
}

enum MirageRenderModePolicy {
    static let healthyDecodeRatio = 0.95
    static let stressedDecodeRatio = 0.80
    static let maxStressBufferDepth = 3

    static func normalizedTargetFPS(_ fps: Int) -> Int {
        fps >= 120 ? 120 : 60
    }
}
