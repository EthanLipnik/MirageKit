//
//  LiveAudioSyncPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//
//  Client-side live audio/video synchronization decisions.
//

import Foundation
import MirageKit

struct LiveAudioSyncPolicy {
    enum VideoState: Equatable, Sendable {
        case fresh(timestampNs: UInt64)
        case waitingForFirstFrame
        case staleAfterPresentation
        case unavailable
    }

    struct Decision: Sendable {
        let frames: [DecodedPCMFrame]
        let droppedCount: Int
        let shouldGatePlayback: Bool
        let runtimeExtraDelaySeconds: Double
        let reason: String?
    }

    static let defaultMaxBehindNs: UInt64 = 500_000_000
    static let defaultLiveTailDurationSeconds: Double = 0.180
    static let defaultMaxHoldSeconds: Double = 0.080

    static func decide(
        frames: [DecodedPCMFrame],
        videoState: VideoState,
        maxBehindNs: UInt64 = defaultMaxBehindNs,
        liveTailDurationSeconds: Double = defaultLiveTailDurationSeconds,
        maxHoldSeconds: Double = defaultMaxHoldSeconds
    ) -> Decision {
        guard !frames.isEmpty else {
            return Decision(
                frames: [],
                droppedCount: 0,
                shouldGatePlayback: false,
                runtimeExtraDelaySeconds: 0,
                reason: nil
            )
        }

        switch videoState {
        case .fresh(let videoTimestampNs):
            let liveFrames = filterFramesBehindVideo(
                frames,
                videoTimestampNs: videoTimestampNs,
                maxBehindNs: maxBehindNs
            )
            let delay = runtimeDelay(for: liveFrames.frames.first, videoTimestampNs: videoTimestampNs, maxHoldSeconds: maxHoldSeconds)
            return Decision(
                frames: liveFrames.frames,
                droppedCount: liveFrames.droppedCount,
                shouldGatePlayback: false,
                runtimeExtraDelaySeconds: delay,
                reason: nil
            )
        case .waitingForFirstFrame:
            return gatedDecision(
                frames: frames,
                liveTailDurationSeconds: liveTailDurationSeconds,
                reason: "waiting-first-video-frame"
            )
        case .staleAfterPresentation:
            return gatedDecision(
                frames: frames,
                liveTailDurationSeconds: liveTailDurationSeconds,
                reason: "stale-video-presentation"
            )
        case .unavailable:
            return gatedDecision(
                frames: frames,
                liveTailDurationSeconds: liveTailDurationSeconds,
                reason: "video-timing-unavailable"
            )
        }
    }

    static func filterFramesBehindVideo(
        _ frames: [DecodedPCMFrame],
        videoTimestampNs: UInt64,
        maxBehindNs: UInt64 = defaultMaxBehindNs
    ) -> (frames: [DecodedPCMFrame], droppedCount: Int) {
        let liveFrames = frames.filter { frame in
            let durationNs = UInt64(max(0, frame.durationSeconds) * 1_000_000_000)
            return frame.timestampNs + durationNs + maxBehindNs >= videoTimestampNs
        }
        return (liveFrames, frames.count - liveFrames.count)
    }

    private static func runtimeDelay(
        for nextFrame: DecodedPCMFrame?,
        videoTimestampNs: UInt64,
        maxHoldSeconds: Double
    ) -> Double {
        guard let nextFrame else { return 0 }
        guard nextFrame.timestampNs > videoTimestampNs else { return 0 }
        let aheadSeconds = Double(nextFrame.timestampNs - videoTimestampNs) / 1_000_000_000
        return min(max(0, aheadSeconds), maxHoldSeconds)
    }

    private static func gatedDecision(
        frames: [DecodedPCMFrame],
        liveTailDurationSeconds: Double,
        reason: String
    ) -> Decision {
        let liveTail = retainLiveTail(frames, durationSeconds: liveTailDurationSeconds)
        return Decision(
            frames: liveTail.frames,
            droppedCount: liveTail.droppedCount,
            shouldGatePlayback: true,
            runtimeExtraDelaySeconds: 0,
            reason: reason
        )
    }

    private static func retainLiveTail(
        _ frames: [DecodedPCMFrame],
        durationSeconds: Double
    ) -> (frames: [DecodedPCMFrame], droppedCount: Int) {
        guard !frames.isEmpty else { return ([], 0) }
        guard durationSeconds > 0 else {
            return ([frames[frames.count - 1]], frames.count - 1)
        }

        var retained: [DecodedPCMFrame] = []
        var retainedDuration = 0.0
        for frame in frames.reversed() {
            retained.append(frame)
            retainedDuration += frame.durationSeconds
            if retainedDuration >= durationSeconds {
                break
            }
        }

        retained.reverse()
        return (retained, frames.count - retained.count)
    }
}
