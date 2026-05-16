//
//  MirageFramePlayoutQueue.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/14/26.
//

import Foundation

/// Queue operations for decoded frames waiting on the client display clock.
struct MirageFramePlayoutQueue {
    struct TrimResult: Equatable, Sendable {
        var overwrittenPendingFrames: Int = 0
        var smoothestQueueDrops: Int = 0
        var smoothestAgeDrops: Int = 0
        var smoothestCatchUpDrops: Int = 0
        var smoothestCapacityDrops: Int = 0
        var lateFrameDrops: Int = 0
        var coalescedFrames: Int = 0

        static let empty = TrimResult()
    }

    struct Selection: Sendable {
        let frame: MirageRenderFrame?
        let trimResult: TrimResult
        let selectedFrameNumber: UInt32?
    }

    static func trimAfterEnqueue(
        frames: inout [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy
    ) -> TrimResult {
        switch policy.latencyMode {
        case .lowestLatency:
            var removed = 0
            while frames.count > policy.maximumQueueDepth {
                frames.removeFirst()
                removed += 1
            }
            return TrimResult(
                overwrittenPendingFrames: removed,
                smoothestQueueDrops: 0,
                lateFrameDrops: 0,
                coalescedFrames: removed
            )
        case .smoothest:
            var removed = 0
            while frames.count > policy.maximumQueueDepth {
                frames.removeFirst()
                removed += 1
            }
            return TrimResult(
                overwrittenPendingFrames: 0,
                smoothestQueueDrops: removed,
                smoothestAgeDrops: 0,
                smoothestCatchUpDrops: 0,
                smoothestCapacityDrops: removed,
                lateFrameDrops: 0,
                coalescedFrames: 0
            )
        }
    }

    static func selectFrame(
        frames: inout [MirageRenderFrame],
        after submittedCursor: MirageRenderCursor,
        policy: MiragePresentationLatencyPolicy,
        presentationDecision: MiragePresentationDecision,
        now: CFAbsoluteTime
    ) -> Selection {
        var trimResult = removeSubmittedFrames(
            from: &frames,
            after: submittedCursor
        )
        guard !frames.isEmpty else {
            return Selection(frame: nil, trimResult: trimResult, selectedFrameNumber: nil)
        }

        switch policy.latencyMode {
        case .lowestLatency:
            let removed = max(0, frames.count - 1)
            if removed > 0 {
                frames.removeFirst(removed)
                trimResult.lateFrameDrops += removed
                trimResult.coalescedFrames += removed
            }
        case .smoothest:
            let expired = removeExpiredSmoothestFrames(
                from: &frames,
                policy: policy,
                now: now
            )
            trimResult.smoothestQueueDrops += expired
            trimResult.smoothestAgeDrops += expired
            let catchUpDrops = removeSmoothestFramesOverTargetDepth(
                from: &frames,
                targetDepth: presentationDecision.queueTargetDepth
            )
            trimResult.smoothestQueueDrops += catchUpDrops
            trimResult.smoothestCatchUpDrops += catchUpDrops
        }

        let frame = frames.first
        return Selection(
            frame: frame,
            trimResult: trimResult,
            selectedFrameNumber: frame?.frameNumber
        )
    }

    private static func removeSubmittedFrames(
        from frames: inout [MirageRenderFrame],
        after submittedCursor: MirageRenderCursor
    ) -> TrimResult {
        while let first = frames.first, !first.cursor.isAfter(submittedCursor) {
            frames.removeFirst()
        }
        return .empty
    }

    private static func removeExpiredSmoothestFrames(
        from frames: inout [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime
    ) -> Int {
        var removed = 0
        while frames.count > 1,
              let first = frames.first,
              comparableFrameAgeMs(first, now: now) > policy.maximumQueueAgeMs {
            frames.removeFirst()
            removed += 1
        }
        return removed
    }

    private static func removeSmoothestFramesOverTargetDepth(
        from frames: inout [MirageRenderFrame],
        targetDepth: Int
    ) -> Int {
        var removed = 0
        while frames.count > max(1, targetDepth) {
            frames.removeFirst()
            removed += 1
        }
        return removed
    }

    private static func comparableFrameAgeMs(_ frame: MirageRenderFrame, now: CFAbsoluteTime) -> Double {
        let ageSeconds = now - frame.decodeTime
        guard ageSeconds >= 0, ageSeconds < 60 else { return 0 }
        return ageSeconds * 1000
    }
}
