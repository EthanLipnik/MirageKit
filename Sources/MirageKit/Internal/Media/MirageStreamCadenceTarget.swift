//
//  MirageStreamCadenceTarget.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/6/26.
//
//  Internal stream cadence and frame-budget model.
//

import CoreGraphics
import Foundation

package struct MirageStreamCadenceTarget: Sendable, Equatable {
    package let sourceFPS: Int
    package let displayFPS: Int
    package let latencyMode: MirageStreamLatencyMode
    package let encodedPixelSize: CGSize

    package init(
        sourceFPS: Int,
        displayFPS: Int? = nil,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        encodedPixelSize: CGSize = .zero
    ) {
        let resolvedSourceFPS = Self.normalizedFPS(sourceFPS)
        self.sourceFPS = resolvedSourceFPS
        self.displayFPS = Self.normalizedFPS(displayFPS ?? resolvedSourceFPS)
        self.latencyMode = latencyMode
        self.encodedPixelSize = encodedPixelSize
    }

    package var sourceFrameBudgetMs: Double {
        1_000.0 / Double(max(1, sourceFPS))
    }

    package var playoutDelayFrames: Int {
        switch latencyMode {
        case .lowestLatency:
            0
        case .smoothest:
            1
        }
    }

    package static func normalizedFPS(_ fps: Int) -> Int {
        max(1, min(240, fps))
    }
}
