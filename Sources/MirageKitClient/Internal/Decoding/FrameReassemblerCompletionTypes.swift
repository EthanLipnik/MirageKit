//
//  FrameReassemblerCompletionTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Internal result carriers for frame reassembly completion.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation

extension FrameReassembler {
    /// Freshness marker for the best pending keyframe while recovering from keyframe starvation.
    struct PendingKeyframeProgress: Equatable {
        let frameNumber: UInt32
        let epoch: UInt16
        let dimensionToken: UInt16
        let receivedFragments: Int
        let dataFragments: Int
        let progressRatio: Double
        let receivedBytes: Int
        let expectedBytes: Int
        let lastProgressTime: CFAbsoluteTime
        let age: CFAbsoluteTime
    }

    struct KeyframeWaitSnapshot: Equatable {
        let isAwaitingKeyframe: Bool
        let awaitingSince: CFAbsoluteTime
        let latestPacketReceivedTime: CFAbsoluteTime
        let latestAcceptedPacketReceivedTime: CFAbsoluteTime
        let packetAcceptanceSnapshot: PacketAcceptanceSnapshot
        let latestPendingKeyframeProgress: PendingKeyframeProgress?
        let transportPathKind: MirageCore.MirageNetworkPathKind
        let mediaPathProfile: MirageMedia.MirageMediaPathProfile
        let pendingFrameCount: Int
        let pendingKeyframeCount: Int
        let incompleteFrameTimeouts: UInt64
        let incompleteFrameNoProgressTimeouts: UInt64
        let incompleteFrameLifetimeTimeouts: UInt64
        let forwardGapTimeouts: UInt64

        init(
            isAwaitingKeyframe: Bool,
            awaitingSince: CFAbsoluteTime,
            latestPacketReceivedTime: CFAbsoluteTime,
            latestAcceptedPacketReceivedTime: CFAbsoluteTime? = nil,
            packetAcceptanceSnapshot: PacketAcceptanceSnapshot? = nil,
            latestPendingKeyframeProgress: PendingKeyframeProgress?,
            transportPathKind: MirageCore.MirageNetworkPathKind,
            mediaPathProfile: MirageMedia.MirageMediaPathProfile,
            pendingFrameCount: Int,
            pendingKeyframeCount: Int,
            incompleteFrameTimeouts: UInt64,
            incompleteFrameNoProgressTimeouts: UInt64,
            incompleteFrameLifetimeTimeouts: UInt64,
            forwardGapTimeouts: UInt64
        ) {
            let inferredPacketCount: UInt64 = latestPacketReceivedTime > 0 ? 1 : 0
            self.isAwaitingKeyframe = isAwaitingKeyframe
            self.awaitingSince = awaitingSince
            self.latestPacketReceivedTime = latestPacketReceivedTime
            self.latestAcceptedPacketReceivedTime = latestAcceptedPacketReceivedTime ?? latestPacketReceivedTime
            self.packetAcceptanceSnapshot = packetAcceptanceSnapshot ?? PacketAcceptanceSnapshot(
                rawPacketsReceived: inferredPacketCount,
                acceptedPacketsReceived: inferredPacketCount
            )
            self.latestPendingKeyframeProgress = latestPendingKeyframeProgress
            self.transportPathKind = transportPathKind
            self.mediaPathProfile = mediaPathProfile
            self.pendingFrameCount = pendingFrameCount
            self.pendingKeyframeCount = pendingKeyframeCount
            self.incompleteFrameTimeouts = incompleteFrameTimeouts
            self.incompleteFrameNoProgressTimeouts = incompleteFrameNoProgressTimeouts
            self.incompleteFrameLifetimeTimeouts = incompleteFrameLifetimeTimeouts
            self.forwardGapTimeouts = forwardGapTimeouts
        }

        var awaitingDuration: CFAbsoluteTime {
            awaitingDuration(now: CFAbsoluteTimeGetCurrent())
        }

        func awaitingDuration(now: CFAbsoluteTime) -> CFAbsoluteTime {
            guard isAwaitingKeyframe, awaitingSince > 0 else { return 0 }
            return max(0, now - awaitingSince)
        }
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

        /// Timed-out non-keyframes that were missing one or more data fragments.
        let incompleteFrameTimeouts: UInt64

        /// Incomplete non-keyframes that timed out because no fragments made progress.
        let incompleteFrameNoProgressTimeouts: UInt64

        /// Incomplete non-keyframes that hit the absolute lifetime cap.
        let incompleteFrameLifetimeTimeouts: UInt64

        /// Total missing data fragments across timed-out incomplete non-keyframes.
        let missingFragmentTimeouts: UInt64

        /// Buffered forward gaps that reached the reorder timeout.
        let forwardGapTimeouts: UInt64

        /// Whether cleanup advanced past a timed-out P-frame gap so later complete frames can decode.
        let skippedForwardGap: Bool

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
