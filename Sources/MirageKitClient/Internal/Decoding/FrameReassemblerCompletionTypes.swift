//
//  FrameReassemblerCompletionTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Internal result carriers for frame reassembly completion.
//

import CoreGraphics
import Foundation
import MirageKit

extension FrameReassembler {
    /// Freshness marker for the best pending keyframe while recovering from keyframe starvation.
    struct PendingKeyframeProgress: Equatable {
        let lastProgressTime: CFAbsoluteTime
    }

    struct CompletedFrame {
        let data: Data
        let isKeyframe: Bool
        let frameNumber: UInt32
        let timestamp: UInt64
        let epoch: UInt16
        let dimensionToken: UInt16
        let contentRect: CGRect
        let releaseBuffer: @Sendable () -> Void
    }

    /// Result of attempting to complete one fragmented video frame.
    struct FrameCompletionResult {
        /// Completed frame ready for decode, if all fragments arrived.
        let frame: CompletedFrame?

        /// Loss reason emitted while completing this frame.
        let frameLossReason: FrameLossReason?

        /// Whether the completed frame is held until earlier frames arrive or time out.
        let retainedForInOrderDelivery: Bool
    }

    /// Batch of completed frames that became deliverable in sequence order.
    struct DrainCompletionResult {
        /// Completed frames ready to decode.
        let frames: [CompletedFrame]

        /// Loss reason discovered while draining retained frames.
        let frameLossReason: FrameLossReason?
    }

    /// Outcome of expiring old incomplete frames from the reassembly buffer.
    struct TimeoutCleanupResult {
        /// Timed-out non-keyframes.
        let timedOutPFrames: UInt64

        /// Timed-out keyframes.
        let timedOutKeyframes: UInt64

        /// Whether a missing expected P-frame gap reached its timeout.
        let missingExpectedPFrameGapTimedOut: Bool

        /// Whether the decoder should wait for a fresh keyframe after cleanup.
        let shouldEnterAwaitingKeyframe: Bool

        /// Frame-loss reason represented by this timeout cleanup.
        var frameLossReason: FrameLossReason? {
            if missingExpectedPFrameGapTimedOut {
                return .forwardGapTimeout
            }
            if timedOutPFrames + timedOutKeyframes > 0 {
                return .timeout
            }
            return nil
        }
    }
}
