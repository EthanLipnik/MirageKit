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
        var smoothestDepthDrops: Int = 0
        var smoothestAgeDrops: Int = 0
        var smoothestDropsUnder100ms: Int = 0
        var smoothestDroppedFrameAgeMaxMs: Double = 0
        var lateFrameDrops: Int = 0
        var coalescedFrames: Int = 0

        static let empty = TrimResult()

        mutating func recordSmoothestDepthDrop(ageMs: Double) {
            smoothestQueueDrops += 1
            smoothestDepthDrops += 1
            recordSmoothestDroppedFrameAge(ageMs)
        }

        mutating func recordSmoothestAgeDrop(ageMs: Double) {
            smoothestQueueDrops += 1
            smoothestAgeDrops += 1
            recordSmoothestDroppedFrameAge(ageMs)
        }

        private mutating func recordSmoothestDroppedFrameAge(_ ageMs: Double) {
            smoothestDroppedFrameAgeMaxMs = max(smoothestDroppedFrameAgeMaxMs, ageMs)
            if ageMs > 0, ageMs < 100 {
                smoothestDropsUnder100ms += 1
            }
        }
    }

    struct Selection: Sendable {
        let frame: MirageRenderFrame?
        let trimResult: TrimResult
        let selectedFrameNumber: UInt32?
    }

    static func trimAfterEnqueue(
        frames: inout [MirageRenderFrame],
        policy: MiragePresentationLatencyPolicy,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
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
            var result = TrimResult()
            while frames.count > policy.maximumQueueDepth {
                let ageMs = frames.first.map { comparableFrameAgeMs($0, now: now) } ?? 0
                frames.removeFirst()
                result.recordSmoothestDepthDrop(ageMs: ageMs)
            }
            return result
        }
    }

    static func selectFrame(
        frames: inout [MirageRenderFrame],
        after submittedCursor: MirageRenderCursor,
        policy: MiragePresentationLatencyPolicy,
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
            trimResult.smoothestQueueDrops += expired.smoothestQueueDrops
            trimResult.smoothestDepthDrops += expired.smoothestDepthDrops
            trimResult.smoothestAgeDrops += expired.smoothestAgeDrops
            trimResult.smoothestDropsUnder100ms += expired.smoothestDropsUnder100ms
            trimResult.smoothestDroppedFrameAgeMaxMs = max(
                trimResult.smoothestDroppedFrameAgeMaxMs,
                expired.smoothestDroppedFrameAgeMaxMs
            )
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
    ) -> TrimResult {
        var result = TrimResult()
        while frames.count > 1,
              let first = frames.first,
              comparableFrameAgeMs(first, now: now) > policy.maximumQueueAgeMs {
            let ageMs = comparableFrameAgeMs(first, now: now)
            frames.removeFirst()
            result.recordSmoothestAgeDrop(ageMs: ageMs)
        }
        return result
    }

    private static func comparableFrameAgeMs(_ frame: MirageRenderFrame, now: CFAbsoluteTime) -> Double {
        let ageSeconds = now - frame.decodeTime
        guard ageSeconds >= 0, ageSeconds < 60 else { return 0 }
        return ageSeconds * 1000
    }
}
