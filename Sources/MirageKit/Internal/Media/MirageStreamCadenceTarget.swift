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

    package var displayFrameBudgetMs: Double {
        1_000.0 / Double(max(1, displayFPS))
    }

    package var pixelRate: Double {
        guard encodedPixelSize.width > 0, encodedPixelSize.height > 0 else { return 0 }
        return Double(encodedPixelSize.width) * Double(encodedPixelSize.height) * Double(sourceFPS)
    }

    package var playoutDelayFrames: Int {
        switch latencyMode {
        case .lowestLatency:
            0
        case .smoothest:
            1
        }
    }

    package var livePendingFrameCapacity: Int {
        max(1, playoutDelayFrames + 1)
    }

    package var reassemblyBacklogStressFrames: Int {
        max(3, Int((Double(sourceFPS) * 0.10).rounded(.up)))
    }

    package var reassemblyBacklogStressBytes: Int {
        let pixelRateScaled = Int(max(8_000_000, min(32_000_000, pixelRate / 12.0)))
        return pixelRate > 0 ? pixelRateScaled : 24 * 1024 * 1024
    }

    package var receiverFPSStableRatio: Double {
        0.88
    }

    package var minimumAdaptiveBitrateBps: Int {
        guard pixelRate > 0 else {
            return sourceFPS >= 120 ? 25_000_000 : 12_000_000
        }
        let bitsPerPixelFrame: Double = if sourceFPS >= 120 {
            0.075
        } else if sourceFPS >= 60 {
            0.085
        } else {
            0.095
        }
        let estimated = Int(pixelRate * bitsPerPixelFrame)
        let floor = sourceFPS >= 120 ? 25_000_000 : sourceFPS >= 60 ? 12_000_000 : 6_000_000
        return max(floor, min(80_000_000, estimated))
    }

    package static func normalizedFPS(_ fps: Int) -> Int {
        max(1, min(240, fps))
    }
}
