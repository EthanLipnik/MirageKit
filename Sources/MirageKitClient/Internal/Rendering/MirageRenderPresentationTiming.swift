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

struct MirageRenderPresentationTiming: Equatable, Sendable {
    let targetFPS: Int
    let playoutDelayFrames: Int
    let displaysImmediately: Bool

    init(
        targetFPS: Int,
        playoutDelayFrames: Int,
        displaysImmediately: Bool
    ) {
        self.targetFPS = MirageRenderModePolicy.normalizedTargetFPS(targetFPS)
        self.playoutDelayFrames = max(
            0,
            min(MirageRenderModePolicy.maximumSmoothestPlayoutDelayFrames, playoutDelayFrames)
        )
        self.displaysImmediately = displaysImmediately
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
        let playoutDelay = frameDurationSeconds * CFTimeInterval(playoutDelayFrames)
        return CMTime(
            seconds: referenceTime + playoutDelay,
            preferredTimescale: timescale
        )
    }
}
