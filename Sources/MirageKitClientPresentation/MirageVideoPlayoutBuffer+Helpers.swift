//
//  MirageVideoPlayoutBuffer+Helpers.swift
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
import CoreVideo
import Foundation

extension MirageVideoPlayoutBuffer {
    func readinessSlackSeconds(policy: MiragePresentationLatencyPolicy) -> CFTimeInterval {
        min(0.004, max(0.001, policy.displayFrameIntervalMs / 3000))
    }

    func maximumRemoteDeltaSeconds(policy: MiragePresentationLatencyPolicy) -> CFTimeInterval {
        let frameInterval = policy.sourceFrameIntervalMs / 1000
        if policy.usesAwdlRealtimePolicy {
            return max(frameInterval * 8, policy.maximumTargetPlayoutDelayMs / 1000)
        }
        if policy.latencyMode == .balanced {
            return max(frameInterval * 6, policy.maximumTargetPlayoutDelayMs / 1000)
        }
        return max(frameInterval * 12, policy.maximumTargetPlayoutDelayMs / 1000)
    }

    func maximumFutureTarget(
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime,
        decodeTime: CFAbsoluteTime
    ) -> CFAbsoluteTime {
        max(now, decodeTime) + policy.maximumTargetPlayoutDelayMs / 1000
    }

    func minimumDelayIncreaseSpacing(reason: DelayIncreaseReason) -> CFTimeInterval {
        switch reason {
        case .underflow, .frameAfterEmptyTick:
            return 0.050
        case .burst:
            return 0.150
        }
    }

    func retainedPixelBufferBytes(_ frames: [MirageRenderFrame]) -> Int {
        frames.reduce(0) { partialResult, frame in
            partialResult + max(1, CVPixelBufferGetDataSize(frame.pixelBuffer))
        }
    }

    func frameAgeMs(_ frame: MirageRenderFrame, now: CFAbsoluteTime) -> Double {
        let ageSeconds = now - frame.decodeTime
        guard ageSeconds >= 0, ageSeconds < 60 else { return 0 }
        return ageSeconds * 1000
    }
}
