//
//  MirageStreamClientRecoveryStatus.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

/// High-level client-side recovery state for a live stream.
public enum MirageStreamClientRecoveryStatus: Sendable, Equatable {
    /// No recovery action is active.
    case idle
    /// Initial stream startup is waiting for stable media.
    case startup
    /// Client is probing whether the stream can move to a higher presentation tier.
    case tierPromotionProbe
    /// Client has requested or is waiting for a recovery keyframe.
    case keyframeRecovery
    /// Client is rebuilding the decode path after a serious stream failure.
    case hardRecovery
    /// Desktop resize completed and the client is waiting for the first matching frame.
    case postResizeAwaitingFirstFrame
}
