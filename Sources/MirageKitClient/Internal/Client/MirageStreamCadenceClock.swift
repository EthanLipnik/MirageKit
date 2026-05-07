//
//  MirageStreamCadenceClock.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/6/26.
//

import CoreMedia
import Foundation

struct MirageStreamFrameTiming: Sendable, Equatable {
    let frameNumber: UInt32
    let remotePresentationTime: CMTime
    let streamPresentationTime: CMTime
    let duplicateRemoteTimestamp: Bool
    let correctedStreamTimestamp: Bool
}

struct MirageStreamCadenceClock: Sendable {
    private(set) var targetFPS: Int
    private var lastFrameNumber: UInt32?
    private var lastRemotePresentationTime: CMTime = .invalid
    private var lastStreamPresentationTime: CMTime = .invalid

    init(targetFPS: Int) {
        self.targetFPS = Self.normalizedFPS(targetFPS)
    }

    mutating func reset(targetFPS: Int? = nil) {
        if let targetFPS {
            self.targetFPS = Self.normalizedFPS(targetFPS)
        }
        lastFrameNumber = nil
        lastRemotePresentationTime = .invalid
        lastStreamPresentationTime = .invalid
    }

    mutating func updateTargetFPS(_ targetFPS: Int) {
        let normalized = Self.normalizedFPS(targetFPS)
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
                CMTimeMultiply(frameDuration, multiplier: Int32(frameStep))
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
            frameNumber: frameNumber,
            remotePresentationTime: remotePresentationTime,
            streamPresentationTime: streamPresentationTime,
            duplicateRemoteTimestamp: duplicateRemoteTimestamp,
            correctedStreamTimestamp: correctedStreamTimestamp
        )
    }

    private var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(1, targetFPS)))
    }

    private static func normalizedFPS(_ fps: Int) -> Int {
        min(240, max(1, fps))
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
