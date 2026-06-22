//
//  MirageRenderPresentationTiming.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
import CoreMedia
import Foundation

/// Shared sample-layer timing policy for render presentation.
package struct MirageRenderPresentationTiming: Equatable, Sendable {
    package let targetFPS: Int
    package let playoutDelayFrames: Int
    package let latencyMode: MirageMedia.MirageStreamLatencyMode
    package let usesFixedRealtimeDisplayPolicy: Bool

    package init(
        targetFPS: Int,
        playoutDelayFrames: Int,
        latencyMode: MirageMedia.MirageStreamLatencyMode,
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

    package var displaysImmediately: Bool {
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

    package var frameDurationSeconds: CFTimeInterval {
        1 / CFTimeInterval(targetFPS)
    }

    package var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(targetFPS))
    }

    package var minimumMonotonicPresentationStep: CMTime {
        displaysImmediately
            ? CMTime(value: 1, timescale: 1_000_000_000)
            : frameDuration
    }

    package func presentationTime(
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
