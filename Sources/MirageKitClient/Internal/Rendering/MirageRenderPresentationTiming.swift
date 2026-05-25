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
    let usesFixedRealtimeDisplayPolicy: Bool

    init(
        targetFPS: Int,
        playoutDelayFrames: Int,
        latencyMode: MirageStreamLatencyMode,
        usesFixedRealtimeDisplayPolicy: Bool = false
    ) {
        self.targetFPS = MirageRenderModePolicy.normalizedTargetFPS(targetFPS)
        self.playoutDelayFrames = max(
            0,
            min(MirageRenderModePolicy.maximumSmoothestPlayoutDelayFrames, playoutDelayFrames)
        )
        self.latencyMode = latencyMode
        self.usesFixedRealtimeDisplayPolicy = usesFixedRealtimeDisplayPolicy
    }

    var displaysImmediately: Bool {
        if usesFixedRealtimeDisplayPolicy {
            return false
        }
        return switch latencyMode {
        case .lowestLatency, .balanced:
            true
        case .smoothest:
            false
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
        let schedulingLead = displaysImmediately ? 0 : min(frameDurationSeconds, 0.008)
        return CMTime(
            seconds: referenceTime + schedulingLead,
            preferredTimescale: timescale
        )
    }
}
