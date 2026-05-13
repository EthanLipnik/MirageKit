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

/// Decides when decoded audio is close enough to live video to play immediately.
enum LiveAudioSyncPolicy {
    /// Video timing state available when audio frames are ready for playback.
    enum VideoState: Equatable {
        /// A recent submitted video presentation timestamp is available.
        case fresh(timestampNs: UInt64)

        /// The stream exists but has not presented its first video frame yet.
        case waitingForFirstFrame

        /// Video presented before, but the latest timestamp is too old for precise alignment.
        case staleAfterPresentation

        /// No active video stream can be matched to the audio stream.
        case unavailable
    }

    /// Playback action for a batch of decoded audio frames.
    struct Decision {
        /// Frames to enqueue or retain after dropping stale backlog.
        let frames: [DecodedPCMFrame]

        /// Number of frames removed from the front of the batch.
        let droppedCount: Int

        /// Whether playback should stay gated until usable video timing arrives.
        let shouldGatePlayback: Bool

        /// Extra playback delay to apply when audio is ahead of fresh video.
        let runtimeExtraDelaySeconds: Double

        /// Diagnostic reason for drops or gating.
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
        case let .fresh(videoTimestampNs):
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
