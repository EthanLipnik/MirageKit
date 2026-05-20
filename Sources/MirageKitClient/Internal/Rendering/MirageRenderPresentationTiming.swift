//
//  MirageRenderPresentationTiming.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//
//  Shared sample-layer timing policy for render presentation.
//

import CoreMedia
import Foundation
import MirageKit

struct MirageRenderPresentationTiming: Equatable, Sendable {
    let targetFPS: Int
    let playoutDelayFrames: Int
    let latencyMode: MirageStreamLatencyMode

    init(
        targetFPS: Int,
        playoutDelayFrames: Int,
        latencyMode: MirageStreamLatencyMode
    ) {
        self.targetFPS = MirageRenderModePolicy.normalizedTargetFPS(targetFPS)
        self.playoutDelayFrames = max(
            0,
            min(MirageRenderModePolicy.maximumSmoothestPlayoutDelayFrames, playoutDelayFrames)
        )
        self.latencyMode = latencyMode
    }

    var displaysImmediately: Bool {
        switch latencyMode {
        case .lowestLatency, .smoothest:
            true
        }
    }

    var frameDurationSeconds: CFTimeInterval {
        1 / CFTimeInterval(targetFPS)
    }

    var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(targetFPS))
    }

    func presentationTime(
        referenceTime: CFTimeInterval,
        timescale: CMTimeScale
    ) -> CMTime {
        let playoutDelay = displaysImmediately ? 0 : frameDurationSeconds * CFTimeInterval(playoutDelayFrames)
        return CMTime(
            seconds: referenceTime + playoutDelay,
            preferredTimescale: timescale
        )
    }
}
