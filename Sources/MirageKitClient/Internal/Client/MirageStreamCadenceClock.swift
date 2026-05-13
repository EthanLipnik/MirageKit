//
//  MirageStreamCadenceClock.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/6/26.
//

import CoreMedia
import Foundation
import MirageKit

/// Presentation timing decision for one decoded stream frame.
struct MirageStreamFrameTiming: Sendable, Equatable {
    /// Monotonic timestamp used by the client presentation pipeline.
    let streamPresentationTime: CMTime
    /// Whether the host repeated the previous remote presentation timestamp.
    let duplicateRemoteTimestamp: Bool
    /// Whether the clock generated a replacement timestamp instead of trusting the host timestamp.
    let correctedStreamTimestamp: Bool
}

/// Maintains monotonic client presentation timestamps for stream frames.
struct MirageStreamCadenceClock: Sendable {
    private(set) var targetFPS: Int
    private var lastFrameNumber: UInt32?
    private var lastRemotePresentationTime: CMTime = .invalid
    private var lastStreamPresentationTime: CMTime = .invalid

    init(targetFPS: Int) {
        self.targetFPS = MirageStreamCadenceTarget.normalizedFPS(targetFPS)
    }

    mutating func reset(targetFPS: Int? = nil) {
        if let targetFPS {
            self.targetFPS = MirageStreamCadenceTarget.normalizedFPS(targetFPS)
        }
        lastFrameNumber = nil
        lastRemotePresentationTime = .invalid
        lastStreamPresentationTime = .invalid
    }

    mutating func updateTargetFPS(_ targetFPS: Int) {
        let normalized = MirageStreamCadenceTarget.normalizedFPS(targetFPS)
        guard normalized != self.targetFPS else { return }
        self.targetFPS = normalized
        lastFrameNumber = nil
        lastStreamPresentationTime = .invalid
    }

    mutating func timing(
        frameNumber: UInt32,
        remotePresentationTime: CMTime,
        isKeyframe: Bool
    ) -> MirageStreamFrameTiming {
        if isKeyframe, let previousFrameNumber = lastFrameNumber,
           !Self.isFrameNewer(frameNumber, than: previousFrameNumber) {
            lastFrameNumber = nil
            lastStreamPresentationTime = .invalid
        }

        let duplicateRemoteTimestamp = remotePresentationTime.isValid &&
            lastRemotePresentationTime.isValid &&
            CMTimeCompare(remotePresentationTime, lastRemotePresentationTime) == 0
        let remoteWentBackward = remotePresentationTime.isValid &&
            lastRemotePresentationTime.isValid &&
            CMTimeCompare(remotePresentationTime, lastRemotePresentationTime) < 0

        let streamPresentationTime: CMTime
        if let previousFrameNumber = lastFrameNumber,
           lastStreamPresentationTime.isValid {
            let frameStep = Self.frameStep(
                from: previousFrameNumber,
                to: frameNumber,
                targetFPS: targetFPS
            )
            streamPresentationTime = CMTimeAdd(
                lastStreamPresentationTime,
                CMTimeMultiply(
                    CMTime(value: 1, timescale: CMTimeScale(max(1, targetFPS))),
                    multiplier: Int32(frameStep)
                )
            )
        } else {
            streamPresentationTime = .zero
        }

        let correctedStreamTimestamp = !remotePresentationTime.isValid ||
            duplicateRemoteTimestamp ||
            remoteWentBackward

        lastFrameNumber = frameNumber
        if remotePresentationTime.isValid {
            lastRemotePresentationTime = remotePresentationTime
        }
        lastStreamPresentationTime = streamPresentationTime

        return MirageStreamFrameTiming(
            streamPresentationTime: streamPresentationTime,
            duplicateRemoteTimestamp: duplicateRemoteTimestamp,
            correctedStreamTimestamp: correctedStreamTimestamp
        )
    }

    private static func frameStep(from previous: UInt32, to current: UInt32, targetFPS: Int) -> UInt32 {
        let delta = current &- previous
        guard delta > 0, delta < UInt32.max / 2 else { return 1 }
        return min(delta, UInt32(max(1, targetFPS)))
    }

    private static func isFrameNewer(_ frameNumber: UInt32, than previousFrameNumber: UInt32) -> Bool {
        frameNumber != previousFrameNumber && (frameNumber &- previousFrameNumber) < UInt32.max / 2
    }
}
